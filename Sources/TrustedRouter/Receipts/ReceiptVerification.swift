import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

// Signed inference receipt verification is intentionally byte-oriented. The
// ordinary SDK SSE parser is permissive for application streams; receipts use
// a stricter parser because their hash domains depend on exact wire fields.

public class ReceiptVerificationError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let message: String

    public required init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

public final class ReceiptStructureError: ReceiptVerificationError, @unchecked Sendable {}
public final class ReceiptHeaderError: ReceiptVerificationError, @unchecked Sendable {}
public final class ReceiptSignatureError: ReceiptVerificationError, @unchecked Sendable {}
public class ReceiptClaimsError: ReceiptVerificationError, @unchecked Sendable {}
public final class ReceiptTimeError: ReceiptClaimsError, @unchecked Sendable {}
public final class ReceiptNonceError: ReceiptClaimsError, @unchecked Sendable {}
public final class ReceiptUpstreamError: ReceiptClaimsError, @unchecked Sendable {}
public final class ReceiptHashError: ReceiptVerificationError, @unchecked Sendable {}
public class ReceiptAttestationError: ReceiptVerificationError, @unchecked Sendable {}
public final class MissingAttestationError: ReceiptAttestationError, @unchecked Sendable {}
public final class UnsupportedAttestationError: ReceiptAttestationError, @unchecked Sendable {}

public struct ReceiptHashClaims: Sendable, Equatable {
    public let alg: String
    public let hash: String
    public let of: String
    public let events: Int?
}

public struct ReceiptModelClaims: Sendable, Equatable {
    public let requested: String
    public let selected: String
    public let provider: String
    public let endpoint: String
}

public struct ReceiptUpstreamClaims: Sendable, Equatable {
    public let tier: String
    public let policy: String?
    public let verifiedAt: Int?
    public let verificationExpiresAt: Int?
    public let certSha256: String?
}

public enum ReceiptAttestationStatus: String, Sendable, Equatable {
    case verified
    case unverifiedByThisSDK = "unverified_by_this_sdk"
}

public struct ReceiptClaims: Sendable, Equatable {
    public let rv: Int
    public let iss: String
    public let iat: Int
    public let jti: String
    public let gen: String?
    public let nonce: String?
    public let route: String
    public let req: ReceiptHashClaims
    public let resp: ReceiptHashClaims
    public let model: ReceiptModelClaims
    public let upstream: ReceiptUpstreamClaims
    public let attSha256: String?
    public let attestationStatus: ReceiptAttestationStatus

    public var attestation: ReceiptAttestationStatus { attestationStatus }
}

public struct ReceiptVerificationOptions: Sendable {
    public var requestBody: Data?
    public var responseBody: Data?
    public var responseStream: Data?
    public var expectedNonce: String?
    public var maxAgeSeconds: TimeInterval?
    public var now: TimeInterval?
    /// Exact GCP Confidential Space attestation JWT bytes for a compact
    /// receipt. The document must match the receipt's `att_sha256` claim.
    public var attestation: Data?
    public var requireAttestation: Bool

    public init(
        requestBody: Data? = nil,
        responseBody: Data? = nil,
        responseStream: Data? = nil,
        expectedNonce: String? = nil,
        maxAgeSeconds: TimeInterval? = nil,
        now: TimeInterval? = nil,
        attestation: Data? = nil,
        requireAttestation: Bool = true
    ) {
        self.requestBody = requestBody
        self.responseBody = responseBody
        self.responseStream = responseStream
        self.expectedNonce = expectedNonce
        self.maxAgeSeconds = maxAgeSeconds
        self.now = now
        self.attestation = attestation
        self.requireAttestation = requireAttestation
    }
}

/// Value representation of a flattened inference-receipt JWS.
public struct FlattenedReceiptJWS: Sendable, Equatable {
    public let protected: String
    public let payload: String
    public let signature: String

    public init(protected: String, payload: String, signature: String) {
        self.protected = protected
        self.payload = payload
        self.signature = signature
    }
}

private struct JWSEnvelope {
    let protected: String
    let payload: String
    let signature: String
    let flattened: Bool
    let flattenedCanonicalJSON: Data?

    var flattenedReceipt: FlattenedReceiptJWS? {
        flattened ? FlattenedReceiptJWS(
            protected: protected,
            payload: payload,
            signature: signature
        ) : nil
    }
}

private let receiptType = "inference-receipt+jws"
private let keyCommitmentDomain = Data("inference-receipt-key-v1\0".utf8)
private let base64URLBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
private let nonceBytes = base64URLBytes

private struct DuplicateRejectingJSONScanner {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func scan() throws {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard offset == bytes.count else { throw failure("unexpected trailing token") }
    }

    private mutating func scanValue() throws {
        skipWhitespace()
        guard offset < bytes.count else { throw failure("unexpected end of input") }
        switch bytes[offset] {
        case 0x7b: try scanObject()       // {
        case 0x5b: try scanArray()        // [
        case 0x22: _ = try scanString()   // "
        case 0x74: try scanLiteral(Array("true".utf8))
        case 0x66: try scanLiteral(Array("false".utf8))
        case 0x6e: try scanLiteral(Array("null".utf8))
        default: try scanNumber()
        }
    }

    private mutating func scanObject() throws {
        offset += 1
        skipWhitespace()
        var keys = Set<String>()
        if consume(0x7d) { return }
        while true {
            guard offset < bytes.count, bytes[offset] == 0x22 else {
                throw failure("object member name must be a string")
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw failure("duplicate JSON member \(String(reflecting: key))")
            }
            skipWhitespace()
            guard consume(0x3a) else { throw failure("expected ':' after object member") }
            try scanValue()
            skipWhitespace()
            if consume(0x7d) { return }
            guard consume(0x2c) else { throw failure("expected ',' or '}' in object") }
            skipWhitespace()
        }
    }

    private mutating func scanArray() throws {
        offset += 1
        skipWhitespace()
        if consume(0x5d) { return }
        while true {
            try scanValue()
            skipWhitespace()
            if consume(0x5d) { return }
            guard consume(0x2c) else { throw failure("expected ',' or ']' in array") }
            skipWhitespace()
        }
    }

    private mutating func scanString() throws -> String {
        let start = offset
        offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]
            if byte == 0x22 {
                offset += 1
                let token = Data(bytes[start..<offset])
                let wrapped = Data([0x5b]) + token + Data([0x5d])
                guard let values = try? JSONSerialization.jsonObject(with: wrapped) as? [String],
                      let value = values.first else {
                    throw failure("invalid JSON string")
                }
                return value
            }
            if byte == 0x5c {
                offset += 1
                guard offset < bytes.count else { throw failure("unterminated string escape") }
                let escaped = bytes[offset]
                if [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escaped) {
                    offset += 1
                    continue
                }
                if escaped == 0x75 {
                    guard offset + 4 < bytes.count else { throw failure("short unicode escape") }
                    for digit in bytes[(offset + 1)...(offset + 4)] where !isHex(digit) {
                        throw failure("invalid unicode escape")
                    }
                    offset += 5
                    continue
                }
                throw failure("invalid string escape")
            }
            guard byte >= 0x20 else { throw failure("unescaped control byte in string") }
            offset += 1
        }
        throw failure("unterminated string")
    }

    private mutating func scanLiteral(_ literal: [UInt8]) throws {
        guard offset + literal.count <= bytes.count,
              Array(bytes[offset..<(offset + literal.count)]) == literal else {
            throw failure("invalid JSON literal")
        }
        offset += literal.count
    }

    private mutating func scanNumber() throws {
        let start = offset
        _ = consume(0x2d)
        guard offset < bytes.count else { throw failure("invalid JSON number") }
        if consume(0x30) {
            if offset < bytes.count, isDigit(bytes[offset]) {
                throw failure("leading zero in JSON number")
            }
        } else {
            guard offset < bytes.count, (0x31...0x39).contains(bytes[offset]) else {
                throw failure("invalid JSON value")
            }
            offset += 1
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        if consume(0x2e) {
            guard offset < bytes.count, isDigit(bytes[offset]) else {
                throw failure("invalid JSON fraction")
            }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        if offset < bytes.count, (bytes[offset] == 0x65 || bytes[offset] == 0x45) {
            offset += 1
            if offset < bytes.count, (bytes[offset] == 0x2b || bytes[offset] == 0x2d) {
                offset += 1
            }
            guard offset < bytes.count, isDigit(bytes[offset]) else {
                throw failure("invalid JSON exponent")
            }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        guard offset > start else { throw failure("invalid JSON value") }
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count, [0x09, 0x0a, 0x0d, 0x20].contains(bytes[offset]) {
            offset += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private func failure(_ detail: String) -> ReceiptStructureError {
        ReceiptStructureError("\(detail) at byte \(offset)")
    }

    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}

private func loadJSON(_ data: Data, check: String) throws -> Any {
    guard String(data: data, encoding: .utf8) != nil else {
        throw ReceiptStructureError("\(check) check failed: invalid UTF-8 JSON")
    }
    do {
        var scanner = DuplicateRejectingJSONScanner(data)
        try scanner.scan()
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch let error as ReceiptStructureError {
        throw ReceiptStructureError("\(check) check failed: invalid JSON: \(error.message)")
    } catch {
        throw ReceiptStructureError("\(check) check failed: invalid JSON: \(error.localizedDescription)")
    }
}

private func parseEnvelope(_ raw: Data) throws -> JWSEnvelope {
    guard raw.allSatisfy({ $0 <= 0x7f }), let ascii = String(data: raw, encoding: .ascii) else {
        throw ReceiptStructureError("JWS structure check failed: receipt bytes must be ASCII")
    }
    let text = ascii.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("{") {
        let value = try loadJSON(Data(text.utf8), check: "JWS structure")
        guard let object = value as? [String: Any] else {
            throw ReceiptStructureError("JWS structure check failed: flattened JWS must be a JSON object")
        }
        return try parseFlattenedEnvelope(object)
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else {
        throw ReceiptStructureError(
            "JWS structure check failed: compact JWS must have 3 non-empty segments, got \(parts.count)"
        )
    }
    return JWSEnvelope(
        protected: String(parts[0]), payload: String(parts[1]),
        signature: String(parts[2]), flattened: false, flattenedCanonicalJSON: nil
    )
}

private func parseFlattenedEnvelope(_ object: [String: Any]) throws -> JWSEnvelope {
    guard object["header"] == nil else {
        throw ReceiptStructureError("JWS structure check failed: unprotected flattened headers are not allowed")
    }
    guard let protected = object["protected"] as? String, !protected.isEmpty,
          let payload = object["payload"] as? String, !payload.isEmpty,
          let signature = object["signature"] as? String, !signature.isEmpty else {
        throw ReceiptStructureError(
            "JWS structure check failed: flattened JWS requires non-empty string protected, payload, and signature members"
        )
    }
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return JWSEnvelope(
        protected: protected,
        payload: payload,
        signature: signature,
        flattened: true,
        flattenedCanonicalJSON: canonical
    )
}

private func base64URLDecode(_ value: String, check: String, allowEmpty: Bool = false) throws -> Data {
    let bytes = Array(value.utf8)
    guard (allowEmpty || !bytes.isEmpty), bytes.allSatisfy(base64URLBytes.contains),
          bytes.count % 4 != 1 else {
        throw ReceiptStructureError("\(check) check failed: invalid base64url encoding")
    }
    var base64 = value.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let decoded = Data(base64Encoded: base64) else {
        throw ReceiptStructureError("\(check) check failed: invalid base64url encoding")
    }
    return decoded
}

private func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func receiptSHA256(_ data: Data) throws -> Data {
    #if canImport(CryptoKit)
    return Data(SHA256.hash(data: data))
    #else
    throw ReceiptSignatureError(
        "CryptoKit check failed: receipt verification requires an Apple platform with CryptoKit"
    )
    #endif
}

private func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
    let length = max(left.count, right.count)
    var difference = left.count ^ right.count
    for index in 0..<length {
        difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
    }
    return difference == 0
}

private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
    constantTimeEqual(Data(left.utf8), Data(right.utf8))
}

private func parseHeader(_ envelope: JWSEnvelope) throws -> ([String: Any], Data) {
    let raw = try base64URLDecode(envelope.protected, check: "protected header")
    let decoded = try loadJSON(raw, check: "protected header")
    guard let header = decoded as? [String: Any] else {
        throw ReceiptHeaderError("protected header check failed: header must be a JSON object")
    }
    guard header["alg"] as? String == "EdDSA" else {
        throw ReceiptHeaderError("protected header alg check failed: expected 'EdDSA'")
    }
    guard header["typ"] as? String == receiptType else {
        throw ReceiptHeaderError("protected header typ check failed: expected '\(receiptType)'")
    }
    guard let jwk = header["jwk"] as? [String: Any] else {
        throw ReceiptHeaderError("protected header jwk check failed: jwk must be an object")
    }
    guard jwk["kty"] as? String == "OKP", jwk["crv"] as? String == "Ed25519",
          jwk["d"] == nil else {
        throw ReceiptHeaderError("protected header jwk check failed: expected a public OKP/Ed25519 JWK")
    }
    guard let x = jwk["x"] as? String else {
        throw ReceiptHeaderError("protected header jwk.x check failed: x must be a string")
    }
    let publicKey: Data
    do {
        publicKey = try base64URLDecode(x, check: "protected header jwk.x")
    } catch let error as ReceiptVerificationError {
        throw ReceiptHeaderError(error.message)
    }
    guard publicKey.count == 32 else {
        throw ReceiptHeaderError(
            "protected header jwk.x check failed: Ed25519 public key is \(publicKey.count) bytes, expected 32"
        )
    }
    let expectedKid = base64URLEncode(try receiptSHA256(publicKey))
    guard let kid = header["kid"] as? String, constantTimeEqual(kid, expectedKid) else {
        throw ReceiptHeaderError(
            "protected header kid check failed: kid does not equal b64url(sha256(jwk.x))"
        )
    }
    return (header, publicKey)
}

private func verifySignature(_ envelope: JWSEnvelope, publicKey: Data) throws -> Data {
    let payload = try base64URLDecode(envelope.payload, check: "JWS payload")
    let signature: Data
    do {
        signature = try base64URLDecode(envelope.signature, check: "JWS signature")
    } catch let error as ReceiptVerificationError {
        throw ReceiptSignatureError(error.message)
    }
    #if canImport(CryptoKit)
    do {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        let input = Data("\(envelope.protected).\(envelope.payload)".utf8)
        guard key.isValidSignature(signature, for: input) else {
            throw ReceiptSignatureError("Ed25519 signature check failed")
        }
    } catch let error as ReceiptSignatureError {
        throw error
    } catch {
        throw ReceiptSignatureError("Ed25519 signature check failed: \(error.localizedDescription)")
    }
    #else
    throw ReceiptSignatureError(
        "CryptoKit check failed: Ed25519 receipt verification requires macOS 10.15+ or iOS 13+"
    )
    #endif
    return payload
}

private func jsonInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let type = String(cString: number.objCType)
    guard ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(type) else { return nil }
    return Int(number.stringValue)
}

private func requiredObject(
    _ object: [String: Any], _ name: String, error: ReceiptVerificationError.Type
) throws -> [String: Any] {
    guard let value = object[name] as? [String: Any] else {
        throw error.init("\(name) claim check failed: required object is missing or invalid")
    }
    return value
}

private func requiredString(
    _ object: [String: Any], _ name: String, family: String = "claims"
) throws -> String {
    guard let value = object[name] as? String, !value.isEmpty else {
        throw ReceiptClaimsError("\(family) \(name) check failed: required string is missing or empty")
    }
    return value
}

private func optionalString(
    _ object: [String: Any], _ name: String, family: String = "claims"
) throws -> String? {
    guard object.keys.contains(name) else { return nil }
    guard let value = object[name] as? String, !value.isEmpty else {
        throw ReceiptClaimsError("\(family) \(name) check failed: value must be a non-empty string")
    }
    return value
}

private func digestClaim(_ object: [String: Any], name: String, response: Bool) throws -> ReceiptHashClaims {
    guard object["alg"] as? String == "sha256" else {
        throw ReceiptHashError("\(name).alg check failed: expected 'sha256'")
    }
    guard let encoded = object["hash"] as? String else {
        throw ReceiptHashError("\(name).hash check failed: required string is missing")
    }
    let digest: Data
    do {
        digest = try base64URLDecode(encoded, check: "\(name).hash")
    } catch let error as ReceiptVerificationError {
        throw ReceiptHashError(error.message)
    }
    guard digest.count == 32 else {
        throw ReceiptHashError("\(name).hash check failed: SHA-256 digest must be 32 bytes")
    }
    guard let of = object["of"] as? String,
          (response ? ["body", "sse-data-v1", "sse-events-v1"].contains(of) : of == "body") else {
        throw ReceiptHashError("\(name).of check failed: unsupported hash domain")
    }
    let events: Int?
    if response && of != "body" {
        if object["events"] == nil || object["events"] is NSNull {
            events = nil
        } else if let value = jsonInteger(object["events"]), value >= 0 {
            events = value
        } else {
            throw ReceiptHashError(
                "\(name).events check failed: value must be a non-negative integer"
            )
        }
    } else {
        guard object["events"] == nil || object["events"] is NSNull else {
            throw ReceiptHashError("\(name).events check failed: body receipts must omit events")
        }
        events = nil
    }
    return ReceiptHashClaims(alg: "sha256", hash: encoded, of: of, events: events)
}

private struct StrictSSEEvent {
    let name: Data
    let payload: Data
    var done: Bool { payload == Data("[DONE]".utf8) }
}

private let lfEventEnd = Data([0x0a, 0x0a])
private let crlfEventEnd = Data([0x0d, 0x0a, 0x0d, 0x0a])

private func findSequence(_ sequence: Data, in data: Data, from start: Int) -> Int? {
    guard !sequence.isEmpty, start <= data.count, sequence.count <= data.count else { return nil }
    let last = data.count - sequence.count
    guard start <= last else { return nil }
    for index in start...last where data[index..<(index + sequence.count)].elementsEqual(sequence) {
        return index
    }
    return nil
}

private func nextSSEEvent(in data: Data, from offset: Int) -> (Data, Int)? {
    let lf = findSequence(lfEventEnd, in: data, from: offset)
    let crlf = findSequence(crlfEventEnd, in: data, from: offset)
    guard lf != nil || crlf != nil else { return nil }
    let end: Int
    if let lf, crlf == nil || lf < crlf! {
        end = lf + lfEventEnd.count
    } else {
        end = crlf! + crlfEventEnd.count
    }
    return (data.subdata(in: offset..<end), end)
}

private func decodeStrictSSEEvent(_ raw: Data) throws -> StrictSSEEvent {
    let body: Data
    if raw.suffix(crlfEventEnd.count) == crlfEventEnd {
        body = Data(raw.dropLast(crlfEventEnd.count))
    } else if raw.suffix(lfEventEnd.count) == lfEventEnd {
        body = Data(raw.dropLast(lfEventEnd.count))
    } else {
        throw ReceiptHashError("response stream framing check failed: incomplete SSE event")
    }
    var name = Data()
    var payload = Data()
    var sawName = false
    var sawData = false
    var lineStart = body.startIndex
    for index in body.indices where body[index] == 0x0a {
        var line = body.subdata(in: lineStart..<index)
        if line.last == 0x0d { line.removeLast() }
        try consumeSSELine(line, name: &name, payload: &payload, sawName: &sawName, sawData: &sawData)
        lineStart = index + 1
    }
    if lineStart <= body.endIndex {
        var line = body.subdata(in: lineStart..<body.endIndex)
        if line.last == 0x0d { line.removeLast() }
        try consumeSSELine(line, name: &name, payload: &payload, sawName: &sawName, sawData: &sawData)
    }
    guard sawData else {
        throw ReceiptHashError("response stream framing check failed: SSE event has no data field")
    }
    return StrictSSEEvent(name: name, payload: payload)
}

private func consumeSSELine(
    _ line: Data, name: inout Data, payload: inout Data,
    sawName: inout Bool, sawData: inout Bool
) throws {
    let dataPrefix = Data("data:".utf8)
    let eventPrefix = Data("event:".utf8)
    if line.starts(with: dataPrefix) {
        guard !sawData else {
            throw ReceiptHashError("response stream framing check failed: SSE event has multiple data fields")
        }
        sawData = true
        payload = Data(line.dropFirst(dataPrefix.count))
        if payload.first == 0x20 { payload.removeFirst() }
    } else if line.starts(with: eventPrefix) {
        guard !sawName else {
            throw ReceiptHashError("response stream framing check failed: SSE event has multiple event fields")
        }
        sawName = true
        name = Data(line.dropFirst(eventPrefix.count))
        if name.first == 0x20 { name.removeFirst() }
    } else {
        throw ReceiptHashError("response stream framing check failed: SSE event contains an unsupported field")
    }
}

private func embeddedReceipt(in payload: Data) throws -> JWSEnvelope? {
    let decoded: Any
    do {
        decoded = try loadJSON(payload, check: "response stream event JSON")
    } catch is ReceiptVerificationError {
        return nil
    }
    guard let object = decoded as? [String: Any], object.keys.contains("inference_receipt") else {
        return nil
    }
    guard let receiptObject = object["inference_receipt"] as? [String: Any] else {
        throw ReceiptHashError(
            "response stream receipt position check failed: inference_receipt must be a flattened JWS object"
        )
    }
    let envelope: JWSEnvelope
    do {
        envelope = try parseFlattenedEnvelope(receiptObject)
    } catch let error as ReceiptVerificationError {
        throw ReceiptHashError("response stream receipt position check failed: \(error.message)")
    }
    return envelope
}

private func streamDigest(
    _ stream: Data, domain: String, expectedEnvelope: JWSEnvelope?
) throws -> (Data, Int) {
    var preimage = Data()
    var eventCount = 0
    var offset = 0
    var sawDone = false
    var sawReceipt = false
    while offset < stream.count {
        guard let (raw, nextOffset) = nextSSEEvent(in: stream, from: offset) else {
            throw ReceiptHashError("response stream framing check failed: stream has an incomplete SSE tail")
        }
        offset = nextOffset
        let event = try decodeStrictSSEEvent(raw)
        if sawDone {
            throw ReceiptHashError("response stream receipt position check failed: data event follows [DONE]")
        }
        if event.done {
            sawDone = true
            continue
        }
        if let embedded = try embeddedReceipt(in: event.payload) {
            guard !sawReceipt else {
                throw ReceiptHashError("response stream receipt position check failed: multiple receipt events")
            }
            guard let expectedEnvelope,
                  embedded.flattenedCanonicalJSON == expectedEnvelope.flattenedCanonicalJSON else {
                throw ReceiptHashError(
                    "response stream receipt position check failed: embedded receipt does not match the verified flattened JWS"
                )
            }
            sawReceipt = true
            continue
        }
        guard !sawReceipt else {
            throw ReceiptHashError(
                "response stream receipt position check failed: receipt is not the last data event before [DONE]"
            )
        }
        if domain == "sse-data-v1" {
            guard event.name.isEmpty else {
                throw ReceiptHashError("response stream hash check failed: sse-data-v1 events must be unnamed")
            }
        } else if domain == "sse-events-v1" {
            preimage.append(event.name)
            preimage.append(0x0a)
        } else {
            throw ReceiptHashError("response stream hash check failed: unsupported domain '\(domain)'")
        }
        preimage.append(event.payload)
        preimage.append(0x0a)
        eventCount += 1
    }
    guard sawReceipt else {
        throw ReceiptHashError("response stream receipt position check failed: receipt event is missing")
    }
    guard sawDone else {
        throw ReceiptHashError(
            "response stream receipt position check failed: receipt is not followed by [DONE]"
        )
    }
    return (try receiptSHA256(preimage), eventCount)
}

typealias ReceiptGCPAttestationVerifier = @Sendable (_ document: Data, _ commitment: Data) async throws -> Void

private func verifyGCPAttestation(_ document: Data, commitment: Data) async throws {
    let policy = try await policyFromTrustRelease()
    try await verifyReceiptKeyAttestation(
        document: document,
        policy: policy,
        keyCommitmentHex: commitment.map { String(format: "%02x", $0) }.joined()
    )
}

private func verifyAttestation(
    envelope: JWSEnvelope,
    header: [String: Any],
    publicKey: Data,
    suppliedAttestation: Data?,
    attSha256: String?,
    requireAttestation: Bool,
    gcpVerifier: ReceiptGCPAttestationVerifier
) async throws -> ReceiptAttestationStatus {
    let document: Data
    if !envelope.flattened {
        guard let suppliedAttestation else {
            guard !requireAttestation else {
                throw MissingAttestationError(
                    "attestation check failed: compact receipts omit attestation evidence; obtain the pinned document or explicitly pass requireAttestation: false"
                )
            }
            return .unverifiedByThisSDK
        }
        guard let attSha256 else {
            throw MissingAttestationError(
                "attestation check failed: compact receipt has no att_sha256 claim"
            )
        }
        let expectedDigest: Data
        do {
            expectedDigest = try base64URLDecode(attSha256, check: "att_sha256 claim")
        } catch let error as ReceiptVerificationError {
            throw ReceiptAttestationError(error.message)
        }
        guard constantTimeEqual(try receiptSHA256(suppliedAttestation), expectedDigest) else {
            throw ReceiptAttestationError(
                "att_sha256 check failed: supplied attestation does not match the compact receipt"
            )
        }
        document = suppliedAttestation
    } else {
        guard let rawKind = header["att_kind"], !(rawKind is NSNull) else {
            throw MissingAttestationError("attestation check failed: flattened receipt has no att_kind")
        }
        guard let kind = rawKind as? String else {
            throw UnsupportedAttestationError("attestation kind check failed: att_kind must be a supported string")
        }
        if kind == "aws-nitro-cose" || kind == "azure-maa-jwt" {
            throw UnsupportedAttestationError("attestation kind check failed: '\(kind)' is not supported by this SDK")
        }
        guard kind == "gcp-cs-jwt" else {
            throw UnsupportedAttestationError("attestation kind check failed: unsupported att_kind '\(kind)'")
        }
        guard let embedded = header["att"] as? String, !embedded.isEmpty else {
            throw MissingAttestationError("attestation check failed: flattened receipt has no embedded att")
        }
        guard embedded.utf8.allSatisfy({ $0 <= 0x7f }) else {
            throw ReceiptAttestationError(
                "attestation check failed: flattened receipt att must be ASCII"
            )
        }
        document = Data(embedded.utf8)
        if let suppliedAttestation,
           !constantTimeEqual(suppliedAttestation, document) {
            throw ReceiptAttestationError(
                "attestation check failed: supplied attestation does not match the flattened receipt's embedded attestation"
            )
        }
    }
    let commitment = try receiptSHA256(keyCommitmentDomain + publicKey)
    do {
        try await gcpVerifier(document, commitment)
    } catch let error as ReceiptVerificationError {
        throw error
    } catch {
        throw ReceiptAttestationError("GCP attestation check failed: \(error.localizedDescription)")
    }
    return .verified
}

/// Verifies a compact or flattened inference receipt and returns its typed v1 claims.
///
/// Compact receipts cannot carry their attestation document. Supply its exact
/// bytes as `ReceiptVerificationOptions.attestation` to check the pinned digest
/// and verify the signing-key binding. `requireAttestation: false` remains an
/// explicit signature-and-hashes-only escape hatch when those bytes are not
/// available. A supplied document for a flattened receipt must equal its
/// embedded document.
///
/// Ed25519 verification uses `CryptoKit.Curve25519.Signing` and therefore has
/// a cryptographic availability floor of macOS 10.15 and iOS 13. The package's
/// declared deployment targets may be higher.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public func verifyReceipt(
    _ receipt: String,
    options: ReceiptVerificationOptions = ReceiptVerificationOptions()
) async throws -> ReceiptClaims {
    try await verifyReceipt(Data(receipt.utf8), options: options)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public func verifyReceipt(
    _ receipt: Data,
    options: ReceiptVerificationOptions = ReceiptVerificationOptions()
) async throws -> ReceiptClaims {
    try await verifyReceipt(
        receipt,
        options: options,
        gcpAttestationVerifier: { document, commitment in
            try await verifyGCPAttestation(document, commitment: commitment)
        }
    )
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public func verifyReceipt(
    _ receipt: FlattenedReceiptJWS,
    options: ReceiptVerificationOptions = ReceiptVerificationOptions()
) async throws -> ReceiptClaims {
    let object: [String: Any] = [
        "protected": receipt.protected,
        "payload": receipt.payload,
        "signature": receipt.signature,
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try await verifyReceipt(data, options: options)
}

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public func verifyReceipt(
    _ receipt: [String: Any],
    options: ReceiptVerificationOptions = ReceiptVerificationOptions()
) async throws -> ReceiptClaims {
    let data: Data
    do {
        data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    } catch {
        throw ReceiptStructureError(
            "JWS structure check failed: flattened JWS is not JSON-serializable: \(error.localizedDescription)"
        )
    }
    return try await verifyReceipt(data, options: options)
}

// Internal injection point used only by frozen-vector tests whose signed
// protected headers deliberately contain placeholder GCP evidence.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
func verifyReceipt(
    _ receipt: Data,
    options: ReceiptVerificationOptions,
    gcpAttestationVerifier: @escaping ReceiptGCPAttestationVerifier
) async throws -> ReceiptClaims {
    let envelope = try parseEnvelope(receipt)
    let (header, publicKey) = try parseHeader(envelope)
    let payloadData = try verifySignature(envelope, publicKey: publicKey)
    let decoded = try loadJSON(payloadData, check: "receipt claims")
    guard let payload = decoded as? [String: Any] else {
        throw ReceiptClaimsError("rv claim check failed: receipt claims must be a JSON object")
    }

    guard let rv = jsonInteger(payload["rv"]), rv == 1 else {
        throw ReceiptClaimsError("rv claim check failed: expected integer 1")
    }
    guard let iat = jsonInteger(payload["iat"]) else {
        throw ReceiptTimeError("iat claim check failed: expected an integer")
    }
    let checkedNow = options.now ?? Date().timeIntervalSince1970
    guard checkedNow.isFinite else {
        throw ReceiptTimeError("iat check failed: now must be finite Unix seconds")
    }
    if TimeInterval(iat) > checkedNow + 60 {
        throw ReceiptTimeError(
            "iat future-skew check failed: iat=\(iat) is more than 60 seconds after now=\(checkedNow)"
        )
    }
    if let maxAge = options.maxAgeSeconds {
        guard maxAge.isFinite, maxAge >= 0 else {
            throw ReceiptTimeError("iat max-age check failed: maxAgeSeconds must be non-negative")
        }
        if checkedNow - TimeInterval(iat) > maxAge {
            throw ReceiptTimeError(
                "iat max-age check failed: receipt age \(checkedNow - TimeInterval(iat))s exceeds \(maxAge)s"
            )
        }
    }

    let iss = try requiredString(payload, "iss")
    let jti = try requiredString(payload, "jti")
    let gen = try optionalString(payload, "gen")
    let route = try requiredString(payload, "route")
    guard ["chat.completions", "responses"].contains(route) else {
        throw ReceiptClaimsError("route claim check failed: unsupported route '\(route)'")
    }
    let modelObject = try requiredObject(payload, "model", error: ReceiptClaimsError.self)
    let model = ReceiptModelClaims(
        requested: try requiredString(modelObject, "requested", family: "model"),
        selected: try requiredString(modelObject, "selected", family: "model"),
        provider: try requiredString(modelObject, "provider", family: "model"),
        endpoint: try requiredString(modelObject, "endpoint", family: "model")
    )
    let attSha256 = try optionalString(payload, "att_sha256")
    if let attSha256 {
        let digest: Data
        do {
            digest = try base64URLDecode(attSha256, check: "att_sha256 claim")
        } catch let error as ReceiptVerificationError {
            throw ReceiptClaimsError(error.message)
        }
        guard digest.count == 32 else {
            throw ReceiptClaimsError("att_sha256 claim check failed: SHA-256 digest must be 32 bytes")
        }
    }
    if !envelope.flattened && attSha256 == nil {
        throw ReceiptClaimsError("att_sha256 claim check failed: compact receipts must pin an attestation document")
    }

    let nonce: String?
    if payload.keys.contains("nonce") {
        guard let value = payload["nonce"] as? String,
              (1...88).contains(value.utf8.count), value.utf8.allSatisfy(nonceBytes.contains) else {
            throw ReceiptNonceError("nonce claim check failed: nonce must contain 1-88 base64url characters")
        }
        nonce = value
    } else {
        nonce = nil
    }
    if let expected = options.expectedNonce,
       nonce == nil || !constantTimeEqual(nonce!, expected) {
        throw ReceiptNonceError("nonce match check failed: expected '\(expected)', got '\(nonce ?? "nil")'")
    }

    let upstreamObject = try requiredObject(payload, "upstream", error: ReceiptUpstreamError.self)
    guard let tier = upstreamObject["tier"] as? String else {
        throw ReceiptUpstreamError("upstream.tier check failed: unsupported tier")
    }
    let verifiedAt: Int?
    let verificationExpiresAt: Int?
    if tier == "tee-verified" {
        guard let verified = jsonInteger(upstreamObject["verified_at"]) else {
            throw ReceiptUpstreamError("upstream.verified_at check failed: expected an integer")
        }
        guard let expires = jsonInteger(upstreamObject["verification_expires_at"]) else {
            throw ReceiptUpstreamError("upstream.verification_expires_at check failed: expected an integer")
        }
        guard verified <= iat, iat < expires else {
            throw ReceiptUpstreamError(
                "tee-verified window check failed: expected verified_at <= iat < verification_expires_at"
            )
        }
        verifiedAt = verified
        verificationExpiresAt = expires
    } else if tier == "tls-webpki" {
        verifiedAt = nil
        verificationExpiresAt = nil
    } else {
        throw ReceiptUpstreamError("upstream.tier check failed: unsupported tier '\(tier)'")
    }
    let policy = try optionalString(upstreamObject, "policy", family: "upstream")
    if tier == "tee-verified", policy == nil {
        throw ReceiptUpstreamError("upstream.policy check failed: tee-verified receipts require a policy")
    }
    let certSha256 = try optionalString(upstreamObject, "cert_sha256", family: "upstream")
    let upstream = ReceiptUpstreamClaims(
        tier: tier, policy: policy, verifiedAt: verifiedAt,
        verificationExpiresAt: verificationExpiresAt, certSha256: certSha256
    )

    let reqObject = try requiredObject(payload, "req", error: ReceiptHashError.self)
    let req = try digestClaim(reqObject, name: "req", response: false)
    if let requestBody = options.requestBody {
        let expected = try base64URLDecode(req.hash, check: "req.hash")
        guard constantTimeEqual(try receiptSHA256(requestBody), expected) else {
            throw ReceiptHashError("request body hash check failed: req.hash does not match")
        }
    }

    let respObject = try requiredObject(payload, "resp", error: ReceiptHashError.self)
    let resp = try digestClaim(respObject, name: "resp", response: true)
    guard options.responseBody == nil || options.responseStream == nil else {
        throw ReceiptHashError("response hash check failed: provide responseBody or responseStream, not both")
    }
    let expectedResponse = try base64URLDecode(resp.hash, check: "resp.hash")
    if let responseBody = options.responseBody {
        guard resp.of == "body" else {
            throw ReceiptHashError("response body hash check failed: resp.of is '\(resp.of)', expected 'body'")
        }
        guard constantTimeEqual(try receiptSHA256(responseBody), expectedResponse) else {
            throw ReceiptHashError("response body hash check failed: resp.hash does not match")
        }
    } else if let responseStream = options.responseStream {
        guard ["sse-data-v1", "sse-events-v1"].contains(resp.of) else {
            throw ReceiptHashError("response stream hash check failed: resp.of is '\(resp.of)', expected an SSE domain")
        }
        let (actual, events) = try streamDigest(
            responseStream, domain: resp.of, expectedEnvelope: envelope
        )
        guard constantTimeEqual(actual, expectedResponse) else {
            throw ReceiptHashError("response stream hash check failed: resp.hash does not match")
        }
        if let claimedEvents = resp.events, events != claimedEvents {
            throw ReceiptHashError(
                "response stream events check failed: counted \(events), receipt claims \(claimedEvents)"
            )
        }
    }

    let attestationStatus = try await verifyAttestation(
        envelope: envelope,
        header: header,
        publicKey: publicKey,
        suppliedAttestation: options.attestation,
        attSha256: attSha256,
        requireAttestation: options.requireAttestation,
        gcpVerifier: gcpAttestationVerifier
    )

    return ReceiptClaims(
        rv: rv, iss: iss, iat: iat, jti: jti, gen: gen, nonce: nonce, route: route,
        req: req, resp: resp, model: model, upstream: upstream,
        attSha256: attSha256, attestationStatus: attestationStatus
    )
}

/// Captures exact SSE wire bytes while forwarding the original byte stream.
///
/// Iterate `stream(from:)` instead of the source stream, then call `verify`.
/// `receipt` becomes non-nil as soon as a complete receipt-bearing event has
/// crossed the stream boundary.
public final class ReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var wire = Data()
    private var scanOffset = 0
    private var discoveredReceipt: FlattenedReceiptJWS?
    private var discoveredReceiptJSON: Data?
    private var configuredSource: TrustedRouterByteStream?

    public init() {}

    public convenience init(source: TrustedRouterByteStream) {
        self.init()
        configuredSource = source
    }

    public var capturedBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return wire
    }

    public var receipt: FlattenedReceiptJWS? {
        lock.lock()
        defer { lock.unlock() }
        return discoveredReceipt
    }

    public func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        wire.append(bytes)
        refreshReceiptLocked()
    }

    public func stream(from source: TrustedRouterByteStream) -> TrustedRouterByteStream {
        let cursor = ReceiptCaptureCursor(source: source, capture: self)
        return AsyncThrowingStream(unfolding: {
            try await cursor.next()
        })
    }

    /// Returns the forwarding stream supplied to `init(source:)`.
    /// A configured source can be consumed only once.
    public func stream() -> TrustedRouterByteStream {
        guard let source = takeConfiguredSource() else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ReceiptStructureError(
                    "receipt capture check failed: no source stream is configured"
                ))
            }
        }
        return stream(from: source)
    }

    public func consume(_ source: TrustedRouterByteStream) async throws {
        for try await byte in source {
            append(Data([byte]))
        }
    }

    public func consume() async throws {
        for try await _ in stream() {}
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    public func verify(
        options: ReceiptVerificationOptions = ReceiptVerificationOptions()
    ) async throws -> ReceiptClaims {
        try await verify(
            options: options,
            gcpAttestationVerifier: { document, commitment in
                try await verifyGCPAttestation(document, commitment: commitment)
            }
        )
    }

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    func verify(
        options: ReceiptVerificationOptions,
        gcpAttestationVerifier: @escaping ReceiptGCPAttestationVerifier
    ) async throws -> ReceiptClaims {
        let (currentReceipt, currentReceiptJSON, currentWire) = snapshot()
        guard currentReceipt != nil else {
            throw ReceiptStructureError(
                "receipt capture check failed: no flattened receipt event has been captured"
            )
        }
        guard options.responseStream == nil else {
            throw ReceiptHashError("ReceiptCapture.verify supplies responseStream from captured bytes")
        }
        var capturedOptions = options
        capturedOptions.responseStream = currentWire
        guard let data = currentReceiptJSON else {
            throw ReceiptStructureError("receipt capture check failed: captured receipt JSON is unavailable")
        }
        return try await verifyReceipt(
            data,
            options: capturedOptions,
            gcpAttestationVerifier: gcpAttestationVerifier
        )
    }

    private func refreshReceiptLocked() {
        while let (raw, nextOffset) = nextSSEEvent(in: wire, from: scanOffset) {
            scanOffset = nextOffset
            guard let event = try? decodeStrictSSEEvent(raw),
                  let embedded = try? embeddedReceipt(in: event.payload) else { continue }
            discoveredReceipt = embedded.flattenedReceipt
            discoveredReceiptJSON = embedded.flattenedCanonicalJSON
        }
    }

    private func snapshot() -> (FlattenedReceiptJWS?, Data?, Data) {
        lock.lock()
        defer { lock.unlock() }
        refreshReceiptLocked()
        return (discoveredReceipt, discoveredReceiptJSON, wire)
    }

    private func takeConfiguredSource() -> TrustedRouterByteStream? {
        lock.lock()
        defer { lock.unlock() }
        let source = configuredSource
        configuredSource = nil
        return source
    }
}

private final class ReceiptCaptureCursor: @unchecked Sendable {
    private var iterator: TrustedRouterByteStream.AsyncIterator
    private let capture: ReceiptCapture

    init(source: TrustedRouterByteStream, capture: ReceiptCapture) {
        self.iterator = source.makeAsyncIterator()
        self.capture = capture
    }

    func next() async throws -> UInt8? {
        guard let byte = try await iterator.next() else { return nil }
        capture.append(Data([byte]))
        return byte
    }
}
