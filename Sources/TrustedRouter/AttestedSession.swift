import Foundation

#if canImport(Network)
@preconcurrency import Dispatch
import Network
import Security

public struct GatewaySession: Sendable {
    public let attestation: GatewayAttestation
    public let connection: NWConnection
    public let exporter: Data
    public let leafDER: Data

    fileprivate let reader: AttestedHTTP1Reader
}

public func verifyGatewaySession(
    baseURL: String,
    policy: AttestationPolicy,
    jwks: [String: Any]? = nil,
    jwksURL: String = GCPJwksURI,
    connectIP: String? = nil,
    timeout: TimeInterval = 15
) async throws -> GatewaySession {
    let target = try GatewaySessionTarget(baseURL: baseURL, connectIP: connectIP)
    let tlsOptions = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
    target.host.withCString {
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, $0)
    }

    let parameters = NWParameters(tls: tlsOptions)
    let connection = NWConnection(
        host: NWEndpoint.Host(target.connectHost),
        port: target.port,
        using: parameters
    )
    let queue = DispatchQueue(label: "com.trustedrouter.attested-session")
    let reader = AttestedHTTP1Reader(connection: connection, hostHeader: target.hostHeader)

    do {
        try await connection.startAndWaitUntilReady(on: queue, timeout: timeout)
        guard let tlsMetadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw AttestationVerificationError("TLS metadata unavailable after connection ready")
        }
        let secMetadata = tlsMetadata.securityProtocolMetadata
        let exporter = try rfc9266Exporter(from: secMetadata)
        let leafDER = try leafCertificateDER(from: secMetadata)
        let freshHex = Data(OAuthCrypto.randomBytes(exporterLength)).hexString
        let document = try await reader.fetchAttestation(nonceHex: freshHex, timeout: timeout)
        let attestation = try await verifyGatewayAttestation(
            document: document,
            policy: policy,
            nonceHex: freshHex,
            tlsCertDer: leafDER,
            tlsExporter: exporter,
            jwks: jwks,
            jwksUrl: jwksURL
        )
        return GatewaySession(
            attestation: attestation,
            connection: connection,
            exporter: exporter,
            leafDER: leafDER,
            reader: reader
        )
    } catch {
        connection.cancel()
        throw error
    }
}

public func fetchAttestationAgain(_ session: GatewaySession, timeout: TimeInterval = 15) async throws -> Data {
    try await session.reader.fetchAttestation(nonceHex: nil, timeout: timeout)
}

private struct GatewaySessionTarget {
    let host: String
    let connectHost: String
    let port: NWEndpoint.Port
    let hostHeader: String

    init(baseURL: String, connectIP: String?) throws {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1") {
            trimmed.removeLast(3)
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            throw AttestationVerificationError("Invalid HTTPS gateway base URL: \(baseURL)")
        }
        let portNumber = url.port ?? 443
        guard portNumber > 0, portNumber <= Int(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber))
        else {
            throw AttestationVerificationError("Invalid gateway port in base URL: \(baseURL)")
        }
        self.host = host
        self.connectHost = connectIP ?? host
        self.port = port
        self.hostHeader = portNumber == 443 ? host : "\(host):\(portNumber)"
    }
}

fileprivate actor AttestedHTTP1Reader {
    private let connection: NWConnection
    private let hostHeader: String
    private var buffer = Data()

    init(connection: NWConnection, hostHeader: String) {
        self.connection = connection
        self.hostHeader = hostHeader
    }

    func fetchAttestation(nonceHex: String?, timeout: TimeInterval) async throws -> Data {
        var path = "/attestation"
        if let nonceHex {
            path += "?nonce=\(nonceHex)"
        }
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "User-Agent: trusted-router-swift/\(TrustedRouterConstants.version)",
            "Accept: application/jwt, application/json, */*",
            "Connection: keep-alive",
            "",
            "",
        ].joined(separator: "\r\n")
        try await connection.sendAll(Data(request.utf8), timeout: timeout)
        let response = try await readHTTPResponse(timeout: timeout)
        if response.connectionCloses {
            connection.cancel()
            throw AttestationVerificationError("attestation response used Connection: close; cannot pin session")
        }
        guard response.statusCode == 200 else {
            throw AttestationVerificationError("attestation fetch returned HTTP \(response.statusCode)")
        }
        return response.body
    }

    private func readHTTPResponse(timeout: TimeInterval) async throws -> HTTPResponse {
        let headerTerminator = Data([13, 10, 13, 10])
        while buffer.range(of: headerTerminator) == nil {
            let chunk = try await connection.receiveChunk(maximumLength: 16 * 1024, timeout: timeout)
            guard let chunk else {
                throw AttestationVerificationError("connection closed before HTTP headers")
            }
            buffer.append(chunk)
        }

        guard let headerRange = buffer.range(of: headerTerminator) else {
            throw AttestationVerificationError("HTTP header parser lost delimiter")
        }
        let headerData = buffer.subdata(in: 0..<headerRange.lowerBound)
        buffer.removeSubrange(0..<headerRange.upperBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw AttestationVerificationError("attestation response headers are not UTF-8")
        }
        let parsed = try HTTPResponseHeaders(headerText: headerText)
        guard let contentLengthText = parsed.headers["content-length"]?.last,
              let contentLength = Int(contentLengthText.trimmingCharacters(in: .whitespaces)),
              contentLength >= 0
        else {
            throw AttestationVerificationError("attestation response missing Content-Length")
        }

        while buffer.count < contentLength {
            let missing = contentLength - buffer.count
            let chunk = try await connection.receiveChunk(maximumLength: max(1, missing), timeout: timeout)
            guard let chunk else {
                throw AttestationVerificationError("connection closed before HTTP body completed")
            }
            buffer.append(chunk)
        }

        let body = buffer.subdata(in: 0..<contentLength)
        buffer.removeSubrange(0..<contentLength)
        return HTTPResponse(
            statusCode: parsed.statusCode,
            headers: parsed.headers,
            body: body,
            connectionCloses: parsed.connectionCloses
        )
    }
}

private struct HTTPResponse {
    let statusCode: Int
    let headers: [String: [String]]
    let body: Data
    let connectionCloses: Bool
}

private struct HTTPResponseHeaders {
    let statusCode: Int
    let headers: [String: [String]]
    let connectionCloses: Bool

    init(headerText: String) throws {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw AttestationVerificationError("attestation response missing HTTP status line")
        }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw AttestationVerificationError("invalid HTTP status line: \(statusLine)")
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw AttestationVerificationError("invalid HTTP header line: \(line)")
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = line.index(after: colon)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name, default: []].append(value)
        }

        self.statusCode = statusCode
        self.headers = headers
        self.connectionCloses = headers["connection"]?.contains { value in
            value
                .split(separator: ",")
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "close" }
        } ?? false
    }
}

private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
        return true
    }
}

private extension NWConnection {
    func startAndWaitUntilReady(on queue: DispatchQueue, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Void>(continuation)
            let timeoutItem = DispatchWorkItem { [weak self] in
                // Cancel ONLY if the timeout actually won the continuation race.
                // A .ready that fires at the deadline can already have resumed
                // the continuation; cancelling then would tear down the
                // just-established pinned connection the caller is about to use.
                if box.resume(throwing: AttestationVerificationError("gateway TLS connection timed out after \(timeout)s")) {
                    self?.cancel()
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if box.resume(returning: ()) {
                        timeoutItem.cancel()
                        self?.stateUpdateHandler = nil
                    }
                case .failed(let error):
                    if box.resume(throwing: error) {
                        timeoutItem.cancel()
                        self?.stateUpdateHandler = nil
                    }
                case .cancelled:
                    if box.resume(throwing: AttestationVerificationError("gateway TLS connection cancelled")) {
                        timeoutItem.cancel()
                        self?.stateUpdateHandler = nil
                    }
                case .setup, .waiting, .preparing:
                    break
                @unknown default:
                    break
                }
            }
            start(queue: queue)
        }
    }

    func sendAll(_ data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Void>(continuation)
            let timeoutItem = DispatchWorkItem { [weak self] in
                // Cancel only if the timeout won the race (see startAndWaitUntilReady).
                if box.resume(throwing: AttestationVerificationError("gateway send timed out after \(timeout)s")) {
                    self?.cancel()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            send(content: data, contentContext: .defaultStream, isComplete: false, completion: .contentProcessed { error in
                if let error {
                    if box.resume(throwing: error) {
                        timeoutItem.cancel()
                    }
                } else if box.resume(returning: ()) {
                    timeoutItem.cancel()
                }
            })
        }
    }

    func receiveChunk(maximumLength: Int, timeout: TimeInterval) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let box = ContinuationBox<Data?>(continuation)
            let timeoutItem = DispatchWorkItem { [weak self] in
                // Cancel only if the timeout won the race (see startAndWaitUntilReady).
                if box.resume(throwing: AttestationVerificationError("gateway receive timed out after \(timeout)s")) {
                    self?.cancel()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error {
                    if box.resume(throwing: error) {
                        timeoutItem.cancel()
                    }
                    return
                }
                if let content, !content.isEmpty {
                    if box.resume(returning: content) {
                        timeoutItem.cancel()
                    }
                    return
                }
                if isComplete {
                    if box.resume(returning: nil) {
                        timeoutItem.cancel()
                    }
                    return
                }
                if box.resume(returning: Data()) {
                    timeoutItem.cancel()
                }
            }
        }
    }
}

private func rfc9266Exporter(from metadata: sec_protocol_metadata_t) throws -> Data {
    let secret = exporterLabel.withCString { label in
        // Network.framework exposes RFC 5705/9266 exporter keying material via
        // sec_protocol_metadata_create_secret. G6 uses no context and 32 bytes.
        sec_protocol_metadata_create_secret(metadata, exporterLabel.utf8.count, label, exporterLength)
    }
    guard let secret else {
        throw AttestationVerificationError("TLS exporter unavailable from Network.framework metadata")
    }
    let dispatchData = secret as DispatchData
    let exporter = dispatchData.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) in
        Data(bytes: pointer, count: dispatchData.count)
    }
    guard exporter.count == exporterLength else {
        throw AttestationVerificationError("TLS exporter length \(exporter.count) did not match \(exporterLength)")
    }
    return exporter
}

private func leafCertificateDER(from metadata: sec_protocol_metadata_t) throws -> Data {
    var leafDER: Data?
    let accessible = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
        guard leafDER == nil else { return }
        let secCertificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
        leafDER = SecCertificateCopyData(secCertificate) as Data
    }
    guard accessible, let leafDER else {
        throw AttestationVerificationError("peer leaf certificate unavailable from TLS metadata")
    }
    return leafDER
}

#else

public struct GatewaySession: Sendable {}

public func verifyGatewaySession(
    baseURL: String,
    policy: AttestationPolicy,
    jwks: [String: Any]? = nil,
    jwksURL: String = GCPJwksURI,
    connectIP: String? = nil,
    timeout: TimeInterval = 15
) async throws -> GatewaySession {
    throw AttestationVerificationError("G6 attested sessions are not supported on this platform (needs Network.framework)")
}

public func fetchAttestationAgain(_ session: GatewaySession, timeout: TimeInterval = 15) async throws -> Data {
    throw AttestationVerificationError("G6 attested sessions are not supported on this platform (needs Network.framework)")
}

#endif
