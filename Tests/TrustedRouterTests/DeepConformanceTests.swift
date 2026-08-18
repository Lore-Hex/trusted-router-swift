import XCTest
@testable import TrustedRouter

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DeepConformanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DeepConformanceProtocol.reset()
    }

    func testHighLevelChatRetriesWithOneStableGeneratedKey() async throws {
        DeepConformanceProtocol.outcomes = [
            .response(503, #"{"error":{"message":"retry"}}"#),
            .response(200, #"data: {"id":"c1","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n")
        ]
        let router = try makeRouter(maxRetries: 1)

        let completion = try await router.chatCompletions(
            messages: [["role": "user", "content": "hi"]]
        )

        XCTAssertEqual(completion.choices.first?.message.content, "ok")
        XCTAssertEqual(DeepConformanceProtocol.requests.count, 2)
        let first = DeepConformanceProtocol.requests[0].value(forHTTPHeaderField: "Idempotency-Key")
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(
            DeepConformanceProtocol.requests[1].value(forHTTPHeaderField: "Idempotency-Key"),
            first
        )
    }

    func testGenericUnkeyedMutationDoesNotRetryAmbiguousTransportFailure() async throws {
        DeepConformanceProtocol.outcomes = [.failure(URLError(.networkConnectionLost))]
        let router = try makeRouter(maxRetries: 2)
        do {
            let _: EmptyResponse = try await router.request(
                method: "POST", path: "/generic-mutation", body: ["value": "once"]
            )
            XCTFail("expected transport failure")
        } catch {}
        XCTAssertEqual(DeepConformanceProtocol.requests.count, 1)
        XCTAssertNil(DeepConformanceProtocol.requests[0]
            .value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testOAuthExchangeStripsInjectedSessionDefaults() async throws {
        DeepConformanceProtocol.outcomes = [.response(200, #"{"key":"delegated"}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepConformanceProtocol.self]
        config.httpAdditionalHeaders = [
            "Authorization": "Bearer ambient",
            "Proxy-Authorization": "Bearer ambient-proxy",
            "Cookie": "session=ambient",
            "Cookie2": "legacy=ambient",
            "X-Api-Key": "ambient-api-key",
            "Idempotency-Key": "ambient-idempotency",
            "X-TR-CLIENT": "v=1;a=99;s=0",
            "X-TrustedRouter-Workspace": "ambient-workspace",
            "X-Trace-Id": "keep-ambient"
        ]

        let token = try await exchangeOAuthKey(
            code: "code",
            baseURL: "https://control.test/v1",
            urlSession: URLSession(configuration: config)
        )

        XCTAssertEqual(token.key, "delegated")
        let request = DeepConformanceProtocol.requests[0]
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie2"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-TR-CLIENT"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-TrustedRouter-Workspace"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace-Id"), "keep-ambient")
    }

    func testRedirectDelegateAlwaysSurfacesOriginalResponse() {
        let session = URLSession(configuration: .ephemeral)
        let original = URL(string: "https://api.test/v1/chat")!
        let redirected = URL(string: "https://attacker.test/collect")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(
            url: original, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected.absoluteString]
        )!
        var accepted: URLRequest? = URLRequest(url: redirected)
        TrustedRouterRedirectBlocker().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)
        ) { accepted = $0 }
        XCTAssertNil(accepted)
    }

    func testAuthenticationDelegateBlocksHTTPAuthButPreservesServerTrust() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://api.test/v1/models")!)
        let sender = RecordingChallengeSender()
        let blocker = TrustedRouterRedirectBlocker()

        func disposition(for method: String) -> URLSession.AuthChallengeDisposition? {
            let protectionSpace = URLProtectionSpace(
                host: "api.test",
                port: 443,
                protocol: "https",
                realm: "test",
                authenticationMethod: method
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: protectionSpace,
                proposedCredential: nil,
                previousFailureCount: 0,
                failureResponse: nil,
                error: nil,
                sender: sender
            )
            var selected: URLSession.AuthChallengeDisposition?
            blocker.urlSession(
                session,
                task: task,
                didReceive: challenge
            ) { disposition, credential in
                XCTAssertNil(credential)
                selected = disposition
            }
            return selected
        }

        XCTAssertEqual(
            disposition(for: "NSURLAuthenticationMethodHTTPBasic"),
            .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            disposition(for: "NSURLAuthenticationMethodHTTPDigest"),
            .cancelAuthenticationChallenge
        )
        XCTAssertEqual(
            disposition(for: "NSURLAuthenticationMethodServerTrust"),
            .performDefaultHandling
        )
    }

    func testHTTPAuthenticationChallengeCannotCreateSecondWireAttempt() async throws {
        AuthenticationChallengeProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthenticationChallengeProtocol.self]
        let router = try TrustedRouter(options: .init(
            apiKey: "sk-test",
            baseUrl: "https://api.test/v1",
            controlBaseURL: "https://api.test/v1",
            urlSession: URLSession(configuration: config),
            maxRetries: 2,
            regionalFailover: false
        ))

        do {
            _ = try await router.models()
            XCTFail("expected the original 401")
        } catch let error as TrustedRouterError {
            guard case let .authentication(statusCode, _, _) = error else {
                XCTFail("expected typed authentication error, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 401)
        }
        XCTAssertEqual(AuthenticationChallengeProtocol.wireAttemptCount, 1)
    }

    func testProxyAuthenticationChallengeCannotCreateSecondWireAttempt() async throws {
        AuthenticationChallengeProtocol.reset(statusCode: 407, isProxy: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthenticationChallengeProtocol.self]
        let router = try TrustedRouter(options: .init(
            apiKey: "sk-test",
            baseUrl: "https://api.test/v1",
            controlBaseURL: "https://api.test/v1",
            urlSession: URLSession(configuration: config),
            maxRetries: 2,
            regionalFailover: false
        ))

        do {
            _ = try await router.models()
            XCTFail("expected the original 407")
        } catch let error as TrustedRouterError {
            guard case let .badRequest(statusCode, _, _) = error else {
                XCTFail("expected typed 407 response, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 407)
        }
        XCTAssertEqual(AuthenticationChallengeProtocol.wireAttemptCount, 1)
    }

    func testInjectedSessionDelegateCannotBypassSessionWideAuthBlocker() async throws {
        AuthenticationChallengeProtocol.reset(
            statusCode: 401,
            authenticationMethod: "NSURLAuthenticationMethodNTLM"
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthenticationChallengeProtocol.self]
        config.urlCredentialStorage = .shared
        let ambientDelegate = AmbientAuthenticationDelegate()
        let injected = URLSession(
            configuration: config,
            delegate: ambientDelegate,
            delegateQueue: nil
        )
        let router = try TrustedRouter(options: .init(
            apiKey: "sk-test",
            baseUrl: "https://api.test/v1",
            controlBaseURL: "https://api.test/v1",
            urlSession: injected,
            maxRetries: 2,
            regionalFailover: false
        ))

        do {
            _ = try await router.models()
            XCTFail("expected the original 401")
        } catch let error as TrustedRouterError {
            guard case let .authentication(statusCode, _, _) = error else {
                XCTFail("expected typed 401 response, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 401)
        }
        XCTAssertTrue(router.urlSession === injected)
        XCTAssertFalse(router.transportURLSession === injected)
        XCTAssertNil(router.transportURLSession.delegate)
        XCTAssertNotNil(injected.configuration.urlCredentialStorage)
        XCTAssertNil(router.transportURLSession.configuration.urlCredentialStorage)
        XCTAssertEqual(ambientDelegate.challengeCount, 0)
        XCTAssertEqual(AuthenticationChallengeProtocol.wireAttemptCount, 1)
    }

    private func makeRouter(maxRetries: Int) throws -> TrustedRouter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepConformanceProtocol.self]
        return try TrustedRouter(options: .init(
            apiKey: "sk-test",
            baseUrl: "https://api.test/v1",
            controlBaseURL: "https://control.test/v1",
            urlSession: URLSession(configuration: config),
            maxRetries: maxRetries,
            regionalFailover: false
        ))
    }
}

private final class RecordingChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

private final class AmbientAuthenticationDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var challenges = 0

    var challengeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return challenges
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        lock.lock()
        challenges += 1
        lock.unlock()
        completionHandler(
            .useCredential,
            URLCredential(user: "ambient", password: "ambient", persistence: .forSession)
        )
    }
}

/// A URLProtocol challenge sender treats `.useCredential` as a hidden second
/// physical attempt. The SDK's per-task delegate must cancel before that path.
private final class AuthenticationChallengeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var statusCode = 401
    nonisolated(unsafe) private static var authenticationMethod =
        "NSURLAuthenticationMethodHTTPBasic"
    nonisolated(unsafe) private static var proxy = false
    private var sender: AuthenticationChallengeSender?

    static func reset(
        statusCode: Int = 401,
        authenticationMethod: String = "NSURLAuthenticationMethodHTTPBasic",
        isProxy: Bool = false
    ) {
        lock.lock()
        attempts = 0
        self.statusCode = statusCode
        self.authenticationMethod = authenticationMethod
        self.proxy = isProxy
        lock.unlock()
    }

    static var wireAttemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    private static func recordAttempt() {
        lock.lock()
        attempts += 1
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recordAttempt()
        let sender = AuthenticationChallengeSender(
            useCredential: { [weak self] in
                Self.recordAttempt()
                self?.finish(status: 200, body: #"{"data":[]}"#)
            },
            rejectCredential: { [weak self] in self?.failAuthentication() }
        )
        self.sender = sender
        let statusCode: Int
        let authenticationMethod: String
        let isProxy: Bool
        Self.lock.lock()
        statusCode = Self.statusCode
        authenticationMethod = Self.authenticationMethod
        isProxy = Self.proxy
        Self.lock.unlock()
        let protectionSpace: URLProtectionSpace
        if isProxy {
            protectionSpace = URLProtectionSpace(
                proxyHost: request.url?.host ?? "proxy.test",
                port: request.url?.port ?? 443,
                type: request.url?.scheme ?? "https",
                realm: "ambient-proxy",
                authenticationMethod: authenticationMethod
            )
        } else {
            protectionSpace = URLProtectionSpace(
                host: request.url?.host ?? "api.test",
                port: request.url?.port ?? 443,
                protocol: request.url?.scheme ?? "https",
                realm: "ambient",
                authenticationMethod: authenticationMethod
            )
        }
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: URLCredential(
                user: "ambient", password: "ambient", persistence: .forSession
            ),
            previousFailureCount: 0,
            failureResponse: HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: statusCode == 407
                    ? ["Proxy-Authenticate": "Basic realm=\"ambient-proxy\""]
                    : ["WWW-Authenticate": "Basic realm=\"ambient\""]
            ),
            error: nil,
            sender: sender
        )
        client?.urlProtocol(self, didReceive: challenge)
    }

    override func stopLoading() {}

    private func failAuthentication() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    private func finish(status: Int, body: String) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: status == 401
                ? ["WWW-Authenticate": "Basic realm=\"ambient\""]
                : ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender {
    private let useCredentialAction: () -> Void
    private let rejectCredentialAction: () -> Void

    init(useCredential: @escaping () -> Void, rejectCredential: @escaping () -> Void) {
        self.useCredentialAction = useCredential
        self.rejectCredentialAction = rejectCredential
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        useCredentialAction()
    }

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        rejectCredentialAction()
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        rejectCredentialAction()
    }

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        rejectCredentialAction()
    }

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        rejectCredentialAction()
    }
}

private final class DeepConformanceProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(Int, String)
        case failure(Error)
    }

    nonisolated(unsafe) static var outcomes: [Outcome] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        outcomes = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard !Self.outcomes.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let outcome = Self.outcomes.removeFirst()
        switch outcome {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": status == 200
                    ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
