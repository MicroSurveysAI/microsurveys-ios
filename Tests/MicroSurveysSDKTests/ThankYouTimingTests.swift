import XCTest
@testable import MicroSurveysSDK

/// The thank-you delay vectors shared by every MicroSurveys SDK (API contract, "Thank-you timing").
final class ThankYouTimingTests: XCTestCase {
    func testContractVectors() {
        let long = "Thanks! We read every response."
        let x160 = String(repeating: "x", count: 160)
        let vectors: [(String?, String?, Int)] = [
            (nil, nil, 1350),
            ("   ", "normal", 1350),
            ("Thanks!", "slow", 2025),
            ("Thanks!", "fast", 945),
            ("Ok", nil, 1300),
            ("Ok", "fast", 910),
            (long, nil, 2550),
            (long, "slow", 3825),
            (long, "fast", 1785),
            (x160, nil, 7000),
            (x160, "slow", 10500),
            (x160, "fast", 4900),
            ("Merci 🌱", nil, 1350),
            ("Thanks!", "unknown", 1350),
        ]
        for (message, pace, expected) in vectors {
            XCTAssertEqual(ThankYouTiming.durationMs(message: message, pace: pace), expected,
                           "message=\(String(describing: message)) pace=\(String(describing: pace))")
        }
    }

    func testMessageFallsBackToDefaultWhenBlank() {
        XCTAssertEqual(ThankYouTiming.message(nil), "Thanks!")
        XCTAssertEqual(ThankYouTiming.message(" \n "), "Thanks!")
        XCTAssertEqual(ThankYouTiming.message("  Merci 🌱 "), "Merci 🌱")
    }

    func testSuccessPaceDecodes() throws {
        func decode(_ extra: String) throws -> Survey {
            let json = #"{ "id": "srv_1", "name": "Juniper checkout", "questions": []\#(extra) }"#
            return try JSONDecoder().decode(Survey.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#", "successPace": "slow""#).successPace, "slow")
        XCTAssertEqual(try decode(#", "successPace": "fast""#).successPace, "fast")
        XCTAssertNil(try decode(#", "successPace": null"#).successPace)
        XCTAssertNil(try decode("").successPace)
        XCTAssertEqual(Survey(id: "s", name: "n", questions: [], successPace: "slow").successPace, "slow")
    }
}
