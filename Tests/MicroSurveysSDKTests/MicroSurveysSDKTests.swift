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
}
