import XCTest
@testable import VirtualBody

/// 服务器地址规整：门禁页里用户随手输入的地址都要能变成可用的基址。
final class APIClientNormalizeTests: XCTestCase {

    func testAddsHTTPSWhenSchemeMissing() {
        XCTAssertEqual(APIClient.normalize("example.com/pet"), "https://example.com/pet")
        XCTAssertEqual(APIClient.normalize("1.2.3.4:8899"), "https://1.2.3.4:8899")
    }

    func testKeepsExplicitHTTPForLocalDebugging() {
        XCTAssertEqual(APIClient.normalize("http://192.168.1.9:8899"), "http://192.168.1.9:8899")
        XCTAssertEqual(APIClient.normalize("HTTP://Example.COM/pet/"), "HTTP://Example.COM/pet")
    }

    func testTrimsWhitespaceAndTrailingSlashes() {
        XCTAssertEqual(APIClient.normalize("  https://a.example/pet///  "), "https://a.example/pet")
    }

    func testEmptyFallsBackToDefaultServer() {
        XCTAssertEqual(APIClient.normalize("   "), AppConfig.defaultServer)
        XCTAssertEqual(APIClient.normalize(""), AppConfig.defaultServer)
    }

    func testIdempotent() {
        let once = APIClient.normalize("samachat.example/pet/")
        XCTAssertEqual(APIClient.normalize(once), once)
    }

    func testInvalidHostThrowsBadURL() {
        XCTAssertThrowsError(try APIClient(base: "https://not a valid host")) { error in
            guard case APIError.badURL = error else {
                return XCTFail("应该是 badURL，实际是 \(error)")
            }
        }
    }

    /// 只输入 "https://" 时不要被结尾斜杠剥成 "https:"（剥空 scheme 会变成非法 URL）。
    func testSchemeOnlyKeepsBothSlashes() {
        XCTAssertEqual(APIClient.normalize("https://"), "https://")
        XCTAssertEqual(APIClient.normalize("  https://  "), "https://")
    }
}
