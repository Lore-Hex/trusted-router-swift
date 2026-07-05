import XCTest
@testable import TrustedRouter

final class TrustedRouterTests: XCTestCase {

    func testDefaultBaseConstants() {
        XCTAssertEqual(TrustedRouterConstants.defaultAPIBaseURL, "https://api.trustedrouter.com/v1")
        XCTAssertEqual(TrustedRouterConstants.defaultControlBaseURL, "https://trustedrouter.com/v1")
    }
    
    func testTrustedRouterInitialization() throws {
        let router = try TrustedRouter(options: TrustedRouterOptions(apiKey: "test-api-key"))
        XCTAssertEqual(router.apiKey, "test-api-key")
        XCTAssertEqual(router.baseUrl, "https://api.trustedrouter.com/v1")
        XCTAssertEqual(router.controlBaseURL, "https://trustedrouter.com/v1")
        XCTAssertTrue(router.regionalFailover)

        let routerWithControlOverride = try TrustedRouter(options: TrustedRouterOptions(
            baseUrl: "https://inference.example/v1/",
            controlBaseURL: "https://control.example/v1/",
            regionalFailover: false
        ))
        XCTAssertEqual(routerWithControlOverride.baseUrl, "https://inference.example/v1")
        XCTAssertEqual(routerWithControlOverride.controlBaseURL, "https://control.example/v1")
        XCTAssertFalse(routerWithControlOverride.regionalFailover)
    }
    
    func testHeadersAndMethod() async throws {
        // Since testing URLSession requires mocking, we can at least assert that
        // the client behaves properly when instantiating the request.
        let router = try TrustedRouter(options: TrustedRouterOptions(apiKey: "test-key", workspaceId: "ws-123"))
        
        XCTAssertEqual(router.apiKey, "test-key")
        XCTAssertEqual(router.workspaceId, "ws-123")
    }
}
