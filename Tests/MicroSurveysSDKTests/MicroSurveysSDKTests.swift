import XCTest
@testable import MicroSurveysSDK

final class MicroSurveysSDKTests: XCTestCase {
    func testInitStoresApiKey() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiKey, "ms_test_abc123")
    }

    func testDefaultBaseURL() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiBaseURL.absoluteString, "https://console.microsurveys.ai")
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

    func testAbsurdConfigValuesAreBounded() throws {
        func decode(_ type: String, _ config: String) throws -> QuestionConfig {
            let json = """
            { "id": "q", "order": 0, "type": "\(type)", "prompt": "?", "config": \(config) }
            """.data(using: .utf8)!
            return try JSONDecoder().decode(Question.self, from: json).config
        }
        // Real configs are left as authored.
        guard case let .scale(min, max, _, _) = try decode("NPS", #"{ "min": 0, "max": 10 }"#) else {
            return XCTFail("expected scale")
        }
        XCTAssertEqual([min, max], [0, 10])
        // Absurd ones are bounded, so the survey can't freeze the app.
        guard case let .scale(lo, hi, _, _) = try decode("NPS", #"{ "min": 0, "max": 1000000000 }"#) else {
            return XCTFail("expected scale")
        }
        XCTAssertEqual([lo, hi], [0, 100])
        guard case let .stars(count) = try decode("CSAT_STAR", #"{ "count": 1000000000 }"#) else {
            return XCTFail("expected stars")
        }
        XCTAssertEqual(count, 100)
        let options = (0..<5000).map { #"{ "value": "\#($0)" }"# }.joined(separator: ",")
        guard case let .singleChoice(opts) = try decode("SINGLE_CHOICE", "{ \"options\": [\(options)] }") else {
            return XCTFail("expected choice")
        }
        XCTAssertEqual(opts.count, 100)
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

    // MARK: - Ingest payloads (API-CONTRACT §3, "Device context")

    func testResponsePayloadCarriesImpressionTriggerAndContext() throws {
        let context = DeviceContext(platform: "ios", appVersion: "3.2.0", osVersion: "26.1", locale: "pt-BR")
        let payload = ResponsePayload(clientId: "r1", surveyId: "s1", endUserId: "u1", completed: true,
                                      submittedAt: "2026-10-20T12:00:00Z", userProps: [:],
                                      impressionId: "i1", triggerId: "t1", context: context, answers: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
        XCTAssertEqual(json["impressionId"] as? String, "i1")
        XCTAssertEqual(json["triggerId"] as? String, "t1")
        XCTAssertEqual(json["context"] as? [String: String],
                       ["platform": "ios", "appVersion": "3.2.0", "osVersion": "26.1", "locale": "pt-BR"])
    }

    func testUnknownContextFieldsAreLeftOut() throws {
        let context = DeviceContext(platform: "ios", appVersion: nil, osVersion: "26.1", locale: nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["platform", "osVersion"])
    }

    // MARK: - Event signals

    func testEventCounterKeepsPropertyNamesNotValues() throws {
        let counter = EventCounter()
        counter.record(name: "checkout", properties: ["cart": 3, "coupon": "SAVE10"], at: Date(timeIntervalSince1970: 1))
        counter.record(name: "checkout", properties: ["screen": "cart"], at: Date(timeIntervalSince1970: 3))
        counter.record(name: "app_opened", at: Date(timeIntervalSince1970: 2))
        let counts = counter.drain()
        XCTAssertEqual(counts.map(\.name), ["checkout", "app_opened"])
        XCTAssertEqual(counts[0].count, 2)
        XCTAssertEqual(counts[0].propertyKeys, ["cart", "coupon", "screen"])
        XCTAssertEqual(counts[0].firstSeenAt, "1970-01-01T00:00:01Z")
        XCTAssertEqual(counts[0].lastSeenAt, "1970-01-01T00:00:03Z")
        let json = String(data: try JSONEncoder().encode(counts), encoding: .utf8)!
        XCTAssertFalse(json.contains("SAVE10"))
        XCTAssertEqual(counter.size, 0)
    }

    func testEventCounterCapsNamesAndKeys() {
        let counter = EventCounter()
        for i in 0..<(EventCounter.maxNames + 5) { counter.record(name: "e\(i)") }
        XCTAssertEqual(counter.size, EventCounter.maxNames)
        var props: [String: Any] = [:]
        for i in 0..<30 { props["k\(i)"] = i }
        counter.record(name: "e0", properties: props)
        XCTAssertEqual(counter.drain().first?.propertyKeys.count, EventCounter.maxKeys)
        counter.record(name: "")
        counter.record(name: String(repeating: "x", count: 201))
        XCTAssertEqual(counter.size, 0)
    }

    func testConfigWithoutEventSignalsDecodesAsOff() throws {
        // Older servers and cached configs don't send the field.
        let old = try JSONDecoder().decode(SDKConfig.self, from: Data(#"{"projectId":"p","surveys":[]}"#.utf8))
        XCTAssertNil(old.eventSignals)
        let on = try JSONDecoder().decode(SDKConfig.self, from: Data(#"{"projectId":"p","surveys":[],"eventSignals":true}"#.utf8))
        XCTAssertEqual(on.eventSignals, true)
    }

    func testASurveyThisVersionCantShowIsSkippedNotTheWholeConfig() throws {
        let json = """
        { "projectId": "p", "surveys": [
          { "id": "new", "name": "New", "questions": [{ "id": "q", "type": "MATRIX", "prompt": "?" }] },
          { "id": "seq", "name": "Seq", "questions": [], "triggers": [{ "id": "t", "type": "FUNNEL", "steps": [] }] },
          { "id": "bad", "questions": [] },
          { "id": "ok", "name": "Ok", "questions": [{ "id": "q", "type": "THUMBS", "prompt": "?" }] }
        ] }
        """
        let config = try JSONDecoder().decode(SDKConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.surveys.map(\.id), ["ok"])
        XCTAssertEqual(config.projectId, "p")
    }

    func testEventCountsBatchShape() throws {
        let batch = EventCountsBatch(events: [EventCount(name: "a", count: 1, firstSeenAt: "t", lastSeenAt: "t", propertyKeys: [])],
                                     context: .init(platform: "ios", appVersion: nil, osVersion: "26.1", locale: nil,
                                                    sdkVersion: MicroSurveysSDK.sdkVersion))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as! [String: Any]
        XCTAssertEqual(json["context"] as? [String: String], ["platform": "ios", "osVersion": "26.1", "sdkVersion": "0.0.0"])
        XCTAssertEqual((json["events"] as? [[String: Any]])?.first?["name"] as? String, "a")
    }

    // MARK: - Live debugger

    func testDebugKeyMatchesOtherSDKs() {
        // Shared vector: the web and React Native SDKs assert the same value.
        XCTAssertEqual(DebugKey.make(projectId: "p1", endUserId: "u1"), "309cd11f")
    }

    func testDebugPropertiesSummariseNestedValues() {
        let props = DebugEntry.displayProperties(["a": String(repeating: "x", count: 250), "b": 2, "c": [1, 2], "d": ["e": 1]])
        XCTAssertEqual(props["a"], .string(String(repeating: "x", count: 200) + "…"))
        XCTAssertEqual(props["b"], .number(2))
        XCTAssertEqual(props["c"], .string("[2 items]"))
        XCTAssertEqual(props["d"], .string("{…}"))
    }

    func testEngineReportsWhyASurveyWasSkipped() throws {
        let decide = { (surveyJSON: String, event: String, props: [String: Any]) -> [Decision] in
            let survey = try! JSONDecoder().decode(Survey.self, from: Data(surveyJSON.utf8))
            let defaults = UserDefaults(suiteName: "debug-test-\(UUID().uuidString)")!
            let engine = TriggerEngine(store: TriggerStateStore(defaults: defaults),
                                       identityProvider: { MSIdentity(anonymousId: "u1") })
            engine.surveysProvider = { [survey] }
            let done = self.expectation(description: "evaluated")
            var got: [Decision] = []
            engine.onEvaluated = { _, _, decisions, _ in got = decisions; done.fulfill() }
            engine.process(name: event, properties: props)
            self.wait(for: [done], timeout: 2)
            return got
        }
        func survey(_ extra: String = "", match: String = "{}", sample: Int = 100) -> String {
            #"{"id":"s1","name":"S","questions":[],"samplePercent":\#(sample),"maxPerUserDays":0\#(extra),"triggers":[{"id":"t","type":"SINGLE","delaySeconds":2,"fireEvery":1,"warmupCount":0,"steps":[{"order":0,"event":"checkout","match":\#(match)}]}]}"#
        }
        XCTAssertEqual(decide(survey(), "checkout", [:]),
                       [Decision(surveyId: "s1", triggerId: "t", reason: .eligible, delaySeconds: 2)])
        XCTAssertEqual(decide(survey(), "app_opened", [:]), [])
        XCTAssertEqual(decide(survey(match: #"{"screen":"cart"}"#), "checkout", ["screen": "home"]).map(\.reason), [.propertyMismatch])
        XCTAssertEqual(decide(survey(#","platforms":["web"]"#), "checkout", [:]).map(\.reason), [.platform])
        XCTAssertEqual(decide(survey(sample: 0), "checkout", [:]).map(\.reason), [.sampledOut])
    }

    func testConfigWithoutDebugUsersDecodes() throws {
        let config = try JSONDecoder().decode(SDKConfig.self, from: Data(#"{"projectId":"p","surveys":[]}"#.utf8))
        XCTAssertNil(config.debugUsers)
    }

    func testCurrentContextIsIOS() {
        let context = DeviceContext.current()
        XCTAssertEqual(context.platform, "ios")
        XCTAssertNotNil(context.osVersion)
    }

    // MARK: - Server events (API-CONTRACT §6)

    func testConfigServerEventsFields() throws {
        let old = try JSONDecoder().decode(SDKConfig.self, from: Data(#"{"projectId":"p","surveys":[]}"#.utf8))
        XCTAssertNil(old.pendingEvents)
        XCTAssertNil(old.serverEvents)
        let raw = Data(#"{"projectId":"p","surveys":[],"pendingEvents":true,"serverEvents":["journey_completed","order_shipped"]}"#.utf8)
        let on = try JSONDecoder().decode(SDKConfig.self, from: raw)
        XCTAssertEqual(on.pendingEvents, true)
        XCTAssertEqual(on.serverEvents, ["journey_completed", "order_shipped"])

        let store = ConfigStore(defaults: UserDefaults(suiteName: "config-test-\(UUID().uuidString)")!)
        XCTAssertFalse(store.pendingEvents)
        XCTAssertEqual(store.serverEvents, [])
        store.save(rawConfig: raw, etag: nil)
        XCTAssertTrue(store.pendingEvents)
        XCTAssertEqual(store.serverEvents, ["journey_completed", "order_shipped"])
    }

    func testPendingEventsShapes() throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PendingEventsRequest(userId: nil, deviceId: "d1")))
        XCTAssertEqual(body as? [String: String], ["deviceId": "d1"])

        let json = #"{"events":[{"id":"e1","name":"journey_completed","properties":{"flow":"airport","n":2},"occurredAt":"2026-11-03T09:03:21.250Z"},{"id":"e2","name":"x","occurredAt":"2026-11-03T09:03:21Z"}]}"#
        let events = try JSONDecoder().decode(PendingEventsResponse.self, from: Data(json.utf8)).events
        XCTAssertEqual(events.map(\.id), ["e1", "e2"])
        XCTAssertEqual(events[0].occurredDate?.timeIntervalSince1970 ?? 0, 1_793_696_601.25, accuracy: 0.001)
        XCTAssertEqual(events[1].occurredDate?.timeIntervalSince1970, 1_793_696_601)
        XCTAssertEqual(events[0].plainProperties["flow"] as? String, "airport")
        XCTAssertEqual(events[0].plainProperties["n"] as? Double, 2)
        XCTAssertEqual(events[1].properties, [:])
    }

    func testReplayOrderIsByOccurredAt() {
        let fallback = Date(timeIntervalSince1970: 1_000)
        let events = [
            PendingEvent(id: "b", name: "b", occurredAt: "2026-11-03T09:00:02.000Z"),
            PendingEvent(id: "a", name: "a", occurredAt: "2026-11-03T09:00:01.000Z"),
            PendingEvent(id: "c", name: "c", occurredAt: "2026-11-03T09:00:02.000Z"),
            PendingEvent(id: "z", name: "z", occurredAt: "not a date"),
        ]
        let ordered = PendingEvent.replayOrder(events, fallback: fallback)
        XCTAssertEqual(ordered.map(\.event.id), ["z", "a", "b", "c"])
        XCTAssertEqual(ordered.first?.at, fallback)
    }

    func testSequenceIgnoresStepFromBeforeItStarted() throws {
        let trigger = try sequenceTrigger(window: nil)
        let started = TriggerSequencer.advance(trigger: trigger, record: TriggerRecord(),
                                               eventName: "page_view", properties: ["screen": "Wallet"], nowT: 1_000).0
        // Step 1 happened before step 0: ignored, and the sequence isn't reset.
        let early = TriggerSequencer.advance(trigger: trigger, record: started,
                                             eventName: "wallet_tap", properties: [:], nowT: 900)
        XCTAssertFalse(early.1)
        XCTAssertEqual(early.0.stepIndex, 1)
        XCTAssertEqual(early.0.startedAt, 1_000)
        // An earlier step-0 event doesn't restart it either.
        let earlyStart = TriggerSequencer.advance(trigger: trigger, record: started,
                                                  eventName: "page_view", properties: ["screen": "Wallet"], nowT: 900)
        XCTAssertEqual(earlyStart.0.startedAt, 1_000)
        // At or after the start, it advances.
        XCTAssertTrue(TriggerSequencer.advance(trigger: trigger, record: started,
                                               eventName: "wallet_tap", properties: [:], nowT: 1_000).1)
    }

    func testReplayedStepUsesEventTimeForSequenceWindow() throws {
        let t: TimeInterval = 1_793_696_601
        var clock = Date(timeIntervalSince1970: t)
        let survey = try JSONDecoder().decode(Survey.self, from: Data(#"{"id":"s1","name":"S","questions":[],"samplePercent":100,"maxPerUserDays":0,"triggers":[{"id":"t","type":"SEQUENCE","sequenceWindowSeconds":7200,"delaySeconds":0,"fireEvery":1,"warmupCount":0,"steps":[{"order":0,"event":"book_click","match":{}},{"order":1,"event":"journey_completed","match":{}}]}]}"#.utf8))
        let defaults = UserDefaults(suiteName: "replay-test-\(UUID().uuidString)")!
        let engine = TriggerEngine(store: TriggerStateStore(defaults: defaults),
                                   identityProvider: { MSIdentity(anonymousId: "u1") },
                                   now: { clock })
        engine.surveysProvider = { [survey] }
        func run(_ name: String, occurredAt: Date? = nil) -> [Decision] {
            let done = expectation(description: name)
            var got: [Decision] = []
            engine.onEvaluated = { _, _, decisions, _ in got = decisions; done.fulfill() }
            engine.process(name: name, properties: [:], occurredAt: occurredAt)
            wait(for: [done], timeout: 2)
            return got
        }

        _ = run("book_click")
        clock = Date(timeIntervalSince1970: t + 60)
        XCTAssertTrue(engine.isWaitingOnServerEvent(serverEvents: ["journey_completed"]))
        XCTAssertFalse(engine.isWaitingOnServerEvent(serverEvents: ["book_click"]))
        // The app opens 20 hours later; the ride finished 40 minutes after booking.
        clock = Date(timeIntervalSince1970: t + 20 * 3600)
        XCTAssertFalse(engine.isWaitingOnServerEvent(serverEvents: ["journey_completed"]),
                       "waiting stops 3 hours after the sequence started")
        XCTAssertEqual(run("journey_completed", occurredAt: Date(timeIntervalSince1970: t + 40 * 60)).map(\.reason),
                       [.eligible])

        // The same step tracked live 20 hours on is outside the 2-hour window.
        _ = run("book_click", occurredAt: Date(timeIntervalSince1970: t + 20 * 3600))
        clock = Date(timeIntervalSince1970: t + 40 * 3600)
        XCTAssertEqual(run("journey_completed").map(\.reason), [.sequenceInProgress])
    }

    func testWaitingOnServerEvent() throws {
        let trigger = try sequenceTrigger(window: nil)
        var record = TriggerRecord()
        let events: Set<String> = ["wallet_tap"]
        func waits(_ record: TriggerRecord?, _ trigger: Trigger, events: Set<String> = events, at nowT: TimeInterval) -> Bool {
            TriggerSequencer.waitsOnServerEvent(trigger: trigger, record: record, serverEvents: events, nowT: nowT)
        }
        XCTAssertFalse(waits(nil, trigger, at: 0))
        XCTAssertFalse(waits(record, trigger, at: 0), "not started")
        record = TriggerSequencer.advance(trigger: trigger, record: record,
                                          eventName: "page_view", properties: ["screen": "Wallet"], nowT: 0).0
        XCTAssertTrue(waits(record, trigger, at: 60))
        XCTAssertFalse(waits(record, trigger, events: ["page_view"], at: 60), "next step isn't a server event")
        XCTAssertTrue(waits(record, trigger, at: 3 * 3600 - 1))
        XCTAssertFalse(waits(record, trigger, at: 3 * 3600), "stops 3 hours after it started")
        let single = try decodeTrigger(#"{"id":"s","type":"SINGLE","steps":[{"order":0,"event":"wallet_tap"}]}"#)
        XCTAssertFalse(waits(record, single, at: 60))
    }

    func testMailboxFetchesAgainOnceAfterAFullPage() {
        func run(pages: [Int], ids: (String?, String?) = ("u1", nil), enabled: Bool = true) -> (fetches: Int, replayed: [Int]) {
            let mailbox = ServerEventsMailbox()
            var fetches = 0
            var replayed: [Int] = []
            let done = expectation(description: "checked")
            done.isInverted = pages.isEmpty
            mailbox.isEnabled = { enabled }
            mailbox.ids = { ids }
            mailbox.fetch = { _, _ in
                let count = pages.isEmpty ? 0 : pages[min(fetches, pages.count - 1)]
                fetches += 1
                return (0..<count).map { PendingEvent(id: "\($0)", name: "e", occurredAt: "2026-11-03T09:00:00Z") }
            }
            mailbox.replay = { events in
                replayed.append(events.count)
                if replayed.count == min(pages.count, 2) { done.fulfill() }
            }
            mailbox.check()
            wait(for: [done], timeout: pages.isEmpty ? 0.3 : 2)
            return (fetches, replayed)
        }
        XCTAssertEqual(run(pages: [3]).replayed, [3])
        XCTAssertEqual(run(pages: [50, 50, 50]).replayed, [50, 50], "one extra call, not a loop")
        XCTAssertEqual(run(pages: [], ids: (nil, nil)).fetches, 0, "no id to ask with")
        XCTAssertEqual(run(pages: [], enabled: false).fetches, 0)
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
