import XCTest
@testable import MicroSurveysSDK

final class MicroSurveysSDKTests: XCTestCase {
    func testInitStoresApiKey() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiKey, "ms_test_abc123")
    }

    func testDefaultBaseURL() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiBaseURL.absoluteString, "https://microsurveys.edubai.ventures")
    }

    // MARK: - Model decoding (cross-platform; no UIKit)

    func testDecodeCESQuestion() throws {
        let json = """
        {
          "id": "qst_1", "order": 0, "type": "CES",
          "prompt": "How easy was it?",
          "required": true,
          "config": { "min": 1, "max": 7, "minLabel": "Very difficult", "maxLabel": "Very easy" }
        }
        """.data(using: .utf8)!
        let q = try JSONDecoder().decode(Question.self, from: json)
        XCTAssertEqual(q.type, .ces)
        XCTAssertTrue(q.isRequired)
        guard case let .scale(min, max, minLabel, maxLabel) = q.config else {
            return XCTFail("expected scale config")
        }
        XCTAssertEqual(min, 1)
        XCTAssertEqual(max, 7)
        XCTAssertEqual(minLabel, "Very difficult")
        XCTAssertEqual(maxLabel, "Very easy")
    }

    func testAnswerValueEncodingShapes() throws {
        let enc = JSONEncoder()
        func encoded(_ v: SurveyAnswerValue) throws -> String {
            String(data: try enc.encode(v), encoding: .utf8)!
        }
        XCTAssertEqual(try encoded(.number(6)), #"{"value":6}"#)
        XCTAssertEqual(try encoded(.thumb(.up)), #"{"value":"up"}"#)
        XCTAssertEqual(try encoded(.emoji("happy")), #"{"value":"happy"}"#)
        XCTAssertEqual(try encoded(.choice("opt_a")), #"{"choice":"opt_a"}"#)
        XCTAssertEqual(try encoded(.text("hi")), #"{"text":"hi"}"#)
    }

    // MARK: - FNV-1a sampling

    func testFNV1aKnownVectors() {
        // Canonical 32-bit FNV-1a reference values.
        XCTAssertEqual(Sampling.fnv1a32(""), 0x811c_9dc5)
        XCTAssertEqual(Sampling.fnv1a32("a"), 0xe40c_292c)
    }

    func testSamplingDeterministicAndSticky() {
        let a = Sampling.inSample(endUserId: "user-123", surveyId: "svy_1", samplePercent: 50)
        let b = Sampling.inSample(endUserId: "user-123", surveyId: "svy_1", samplePercent: 50)
        XCTAssertEqual(a, b, "same (user, survey) must give the same decision")
    }

    func testSamplingBoundaries() {
        XCTAssertTrue(Sampling.inSample(endUserId: "x", surveyId: "y", samplePercent: 100))
        XCTAssertFalse(Sampling.inSample(endUserId: "x", surveyId: "y", samplePercent: 0))
    }

    func testSamplingBucketMatchesFNV() {
        // The decision must equal the documented FNV-1a-based bucket formula.
        let bucket = Int(Sampling.fnv1a32("user-123:svy_1") % 100)
        XCTAssertEqual(Sampling.inSample(endUserId: "user-123", surveyId: "svy_1", samplePercent: bucket + 1), true)
        XCTAssertEqual(Sampling.inSample(endUserId: "user-123", surveyId: "svy_1", samplePercent: bucket), false)
    }

    // MARK: - Match evaluation

    func testStringifyNumberAndStringEqual() {
        XCTAssertEqual(MatchEvaluator.stringify(42), "42")
        XCTAssertEqual(MatchEvaluator.stringify(42.0), "42")
        XCTAssertEqual(MatchEvaluator.stringify("Wallet"), "Wallet")
        XCTAssertEqual(MatchEvaluator.stringify(JSONValue.number(42)), "42")
        XCTAssertEqual(MatchEvaluator.stringify(JSONValue.string("Wallet")), "Wallet")
        XCTAssertNil(MatchEvaluator.stringify(JSONValue.null))
    }

    func testStepMatch() throws {
        let step = try decodeStep(#"{ "order": 0, "event": "page_view", "match": { "screen": "Wallet" } }"#)
        XCTAssertTrue(MatchEvaluator.eventMatchesStep(eventName: "page_view",
                                                      properties: ["screen": "Wallet", "extra": 1],
                                                      step: step))
        XCTAssertFalse(MatchEvaluator.eventMatchesStep(eventName: "page_view",
                                                       properties: ["screen": "Home"],
                                                       step: step))
        XCTAssertFalse(MatchEvaluator.eventMatchesStep(eventName: "other_event",
                                                       properties: ["screen": "Wallet"],
                                                       step: step))
    }

    func testEmptyMatchMatchesByNameAlone() throws {
        let step = try decodeStep(#"{ "order": 0, "event": "wallet_tap", "match": {} }"#)
        XCTAssertTrue(MatchEvaluator.eventMatchesStep(eventName: "wallet_tap",
                                                      properties: [:],
                                                      step: step))
    }

    func testAudienceMatch() {
        let audience: [String: JSONValue] = ["plan": .string("pro")]
        XCTAssertTrue(MatchEvaluator.audienceMatches(audience, userProperties: ["plan": .string("pro"), "x": .number(1)]))
        XCTAssertFalse(MatchEvaluator.audienceMatches(audience, userProperties: ["plan": .string("free")]))
        XCTAssertFalse(MatchEvaluator.audienceMatches(audience, userProperties: [:]))
    }

    // MARK: - Trigger sequencing

    func testSingleTriggerSatisfiesOnMatch() throws {
        let trigger = try decodeTrigger("""
        { "id": "s", "type": "SINGLE",
          "steps": [ { "order": 0, "event": "booking_completed", "match": { "plan": "pro" } } ] }
        """)
        let (_, satProp) = TriggerSequencer.advance(trigger: trigger, record: TriggerRecord(),
                                                    eventName: "booking_completed",
                                                    properties: ["plan": "pro"], nowT: 0)
        XCTAssertTrue(satProp)

        let (_, satNo) = TriggerSequencer.advance(trigger: trigger, record: TriggerRecord(),
                                                  eventName: "booking_completed",
                                                  properties: ["plan": "free"], nowT: 0)
        XCTAssertFalse(satNo)
    }

    func testSequenceInOrderWithinWindow() throws {
        let trigger = try sequenceTrigger(window: 60)
        var record = TriggerRecord()

        let step0 = TriggerSequencer.advance(trigger: trigger, record: record,
                                             eventName: "page_view", properties: ["screen": "Wallet"], nowT: 0)
        record = step0.0
        XCTAssertFalse(step0.1)
        XCTAssertEqual(record.stepIndex, 1)

        let step1 = TriggerSequencer.advance(trigger: trigger, record: record,
                                             eventName: "wallet_tap", properties: [:], nowT: 10)
        record = step1.0
        XCTAssertTrue(step1.1)
        XCTAssertEqual(record.stepIndex, 0)
        XCTAssertEqual(record.satisfiedCount, 1)
    }

    func testSequenceWindowExpiryResets() throws {
        let trigger = try sequenceTrigger(window: 60)
        var record = TriggerRecord()

        record = TriggerSequencer.advance(trigger: trigger, record: record,
                                          eventName: "page_view", properties: ["screen": "Wallet"], nowT: 0).0
        XCTAssertEqual(record.stepIndex, 1)

        // Second step arrives after the window — should NOT satisfy, resets.
        let late = TriggerSequencer.advance(trigger: trigger, record: record,
                                            eventName: "wallet_tap", properties: [:], nowT: 100)
        XCTAssertFalse(late.1)
        XCTAssertEqual(late.0.stepIndex, 0)
    }

    func testSequenceIgnoresOutOfOrderEvents() throws {
        let trigger = try sequenceTrigger(window: nil)
        // Second step first → nothing advances.
        let r = TriggerSequencer.advance(trigger: trigger, record: TriggerRecord(),
                                         eventName: "wallet_tap", properties: [:], nowT: 0)
        XCTAssertFalse(r.1)
        XCTAssertEqual(r.0.stepIndex, 0)
    }

    func testSequenceRestartsOnRepeatedStepZero() throws {
        let trigger = try sequenceTrigger(window: 60)
        var record = TriggerSequencer.advance(trigger: trigger, record: TriggerRecord(),
                                              eventName: "page_view", properties: ["screen": "Wallet"], nowT: 0).0
        // A fresh step-0 event restarts the window.
        let restart = TriggerSequencer.advance(trigger: trigger, record: record,
                                               eventName: "page_view", properties: ["screen": "Wallet"], nowT: 50)
        record = restart.0
        XCTAssertFalse(restart.1)
        XCTAssertEqual(record.stepIndex, 1)
        XCTAssertEqual(record.startedAt, 50)
    }

    // MARK: - Theme decoding

    func testThemeDecodesFromConfigEnvelope() throws {
        let json = """
        {
          "projectId": "prj_1",
          "theme": { "accent": "#4F46E5", "cornerRadius": 14, "position": "bottom" },
          "surveys": []
        }
        """.data(using: .utf8)!
        let env = try JSONDecoder().decode(ThemeEnvelope.self, from: json)
        XCTAssertEqual(env.theme?.accent, "#4F46E5")
        XCTAssertEqual(env.theme?.cornerRadius, 14)
        XCTAssertEqual(env.theme?.position, "bottom")
    }

    // MARK: - JSONValue bridging

    func testJSONValueFromAny() {
        XCTAssertEqual(JSONValue(any: "x"), .string("x"))
        XCTAssertEqual(JSONValue(any: 3), .number(3))
        XCTAssertEqual(JSONValue(any: nil), .null)
    }

    // MARK: - Helpers

    private func decodeStep(_ json: String) throws -> TriggerStep {
        try JSONDecoder().decode(TriggerStep.self, from: json.data(using: .utf8)!)
    }

    private func decodeTrigger(_ json: String) throws -> Trigger {
        try JSONDecoder().decode(Trigger.self, from: json.data(using: .utf8)!)
    }

    private func sequenceTrigger(window: Int?) throws -> Trigger {
        let windowJSON = window.map { "\"sequenceWindowSeconds\": \($0)," } ?? ""
        return try decodeTrigger("""
        { "id": "t", "type": "SEQUENCE", \(windowJSON)
          "steps": [
            { "order": 0, "event": "page_view",  "match": { "screen": "Wallet" } },
            { "order": 1, "event": "wallet_tap", "match": {} }
          ] }
        """)
    }
}
