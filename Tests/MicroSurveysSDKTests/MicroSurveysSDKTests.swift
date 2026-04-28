import XCTest
@testable import MicroSurveysSDK

final class MicroSurveysSDKTests: XCTestCase {
    func testInitStoresApiKey() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiKey, "ms_test_abc123")
    }

    func testDefaultBaseURL() {
        let sdk = MicroSurveysSDK(apiKey: "ms_test_abc123")
        XCTAssertEqual(sdk.apiBaseURL.absoluteString, "https://api.microsurveys.io")
    }
}
