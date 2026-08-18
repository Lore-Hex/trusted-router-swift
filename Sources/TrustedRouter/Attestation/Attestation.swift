import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public struct GatewayAttestation: Sendable {
    public var certSha256: String
    public var imageDigest: String
    public var imageReference: String
    public var nonce: String?
    public var expiresAt: Int?
    public var issuer: String?
    public var audience: String
    public var rawClaims: [String: SendableValue]
    
    public init(
        certSha256: String,
        imageDigest: String,
        imageReference: String,
        nonce: String?,
        expiresAt: Int?,
        issuer: String?,
        audience: String,
        rawClaims: [String: SendableValue]
    ) {
        self.certSha256 = certSha256
        self.imageDigest = imageDigest
        self.imageReference = imageReference
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.issuer = issuer
        self.audience = audience
        self.rawClaims = rawClaims
    }
}

/// A simple recursive Sendable value type to store JSON-like claims without [String: Any].
public enum SendableValue: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([SendableValue])
    case dictionary([String: SendableValue])
    case null
    
    static func from(any: Any?) -> SendableValue {
        guard let any = any else { return .null }
        if let s = any as? String { return .string(s) }
        if let n = any as? Double { return .number(n) }
        if let n = any as? Int { return .number(Double(n)) }
        if let b = any as? Bool { return .bool(b) }
        if let a = any as? [Any] { return .array(a.map { from(any: $0) }) }
        if let d = any as? [String: Any] { return .dictionary(d.mapValues { from(any: $0) }) }
        return .null
    }
}

public struct AttestationPolicy: Sendable {
    public var audience: String
    public var certSha256: String?
    public var imageDigest: String?
    public var imageDigests: [String]
    public var imageReference: String?
    public var imageReferences: [String]
    public var allowDebug: Bool

    public init(
        audience: String = "quill-cloud",
        certSha256: String? = nil,
        imageDigest: String? = nil,
        imageDigests: [String] = [],
        imageReference: String? = nil,
        imageReferences: [String] = [],
        allowDebug: Bool = false
    ) {
        self.audience = audience
        self.certSha256 = certSha256
        self.imageDigest = imageDigest
        self.imageDigests = imageDigests
        self.imageReference = imageReference
        self.imageReferences = imageReferences
        self.allowDebug = allowDebug
    }

    /// Whether this policy constrains *which* workload image is acceptable.
    ///
    /// Both image checks in `verifyGatewayAttestation` are guarded on a
    /// non-empty accepted list, so a policy pinning neither a digest nor a
    /// reference accepts any genuinely-attested Confidential Space workload —
    /// it proves "some CSP VM" rather than "the gateway build we published".
    /// Policy construction and verification both refuse that state rather than
    /// silently downgrading the guarantee.
    public var pinsImageIdentity: Bool {
        !imageDigests.isEmpty
            || !(imageDigest ?? "").isEmpty
            || !imageReferences.isEmpty
            || !(imageReference ?? "").isEmpty
    }
}

public struct AttestationVerificationError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public let GCPIssuer = "https://confidentialcomputing.googleapis.com"
public let GCPJwksURI = "https://www.googleapis.com/service_accounts/v1/metadata/jwk/signer@confidentialspace-sign.iam.gserviceaccount.com"
public let exporterLabel = "EXPORTER-Channel-Binding"
public let exporterLength = 32

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    var difference = lhsBytes.count ^ rhsBytes.count
    for i in 0..<max(lhsBytes.count, rhsBytes.count) {
        let l = i < lhsBytes.count ? lhsBytes[i] : 0
        let r = i < rhsBytes.count ? rhsBytes[i] : 0
        difference |= Int(l ^ r)
    }
    return difference == 0
}

extension TrustedRouter {
    public func attestation() async throws -> Data {
        let urlString = self.baseUrl.replacingOccurrences(of: "/v1$", with: "", options: .regularExpression) + "/attestation"
        guard let url = URL(string: urlString) else {
            throw TrustedRouterError.internalError("Invalid attestation URL: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.setValue("trusted-router-swift/\(TrustedRouterConstants.version)", forHTTPHeaderField: "user-agent")
        
        let (data, response) = try await credentialFreeURLSession.trustedRouterData(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrustedRouterError.internalError("Non-HTTP response")
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            throw TrustedRouterError.generic(statusCode: httpResponse.statusCode, message: "Attestation fetch failed", payload: nil)
        }
        return data
    }
    
    public func trustRelease(url: String = TrustedRouterConstants.defaultTrustReleaseURL) async throws -> [String: Any] {
        return try await fetchTrustRelease(trustUrl: url, urlSession: self.urlSession)
    }
}

public func fetchTrustRelease(trustUrl: String = TrustedRouterConstants.defaultTrustReleaseURL, urlSession: URLSession = .shared) async throws -> [String: Any] {
    if let reservedName = ClientTelemetry.reservedHeaderInSessionDefaults(urlSession) {
        throw reservedTelemetrySessionDefaultError(reservedName, entryPoint: "fetchTrustRelease")
    }
    guard let url = URL(string: trustUrl) else {
        throw TrustedRouterError.internalError("Invalid trust release URL")
    }
    var req = URLRequest(url: url)
    req.setValue("trusted-router-swift/\(TrustedRouterConstants.version)", forHTTPHeaderField: "user-agent")
    
    let (data, response) = try await urlSession.trustedRouterCredentialFreeCopy()
        .trustedRouterData(for: req)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw TrustedRouterError.internalError("Non-HTTP response")
    }
    if !(200..<300).contains(httpResponse.statusCode) {
        throw TrustedRouterError.generic(statusCode: httpResponse.statusCode, message: "Trust release fetch failed", payload: nil)
    }
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TrustedRouterError.internalError("Invalid JSON in trust release")
    }
    return dict
}

public func policyFromTrustRelease(
    release: [String: Any]? = nil,
    audience: String = "quill-cloud",
    certSha256: String? = nil,
    trustReleaseUrl: String = TrustedRouterConstants.defaultTrustReleaseURL,
    urlSession: URLSession = .shared
) async throws -> AttestationPolicy {
    let rel: [String: Any]
    if let release = release {
        rel = release
    } else {
        if let reservedName = ClientTelemetry.reservedHeaderInSessionDefaults(urlSession) {
            throw reservedTelemetrySessionDefaultError(
                reservedName, entryPoint: "policyFromTrustRelease"
            )
        }
        rel = try await fetchTrustRelease(trustUrl: trustReleaseUrl, urlSession: urlSession)
    }
    let imageDigest = rel["image_digest"] as? String
    let publishedDigests = (rel["accepted_image_digests"] as? [String])?
        .filter { !$0.isEmpty } ?? []
    let imageReference = rel["image_reference"] as? String
    let publishedReferences = (rel["accepted_image_references"] as? [String])?
        .filter { !$0.isEmpty } ?? []
    let policy = AttestationPolicy(
        audience: audience,
        certSha256: certSha256,
        imageDigest: imageDigest,
        imageDigests: publishedDigests.isEmpty ? imageDigest.map { [$0] } ?? [] : publishedDigests,
        imageReference: imageReference,
        imageReferences: publishedReferences.isEmpty ? imageReference.map { [$0] } ?? [] : publishedReferences
    )
    guard policy.pinsImageIdentity else {
        // A truncated body, an error page that happens to parse as JSON, or a
        // schema change all land here. Returning the policy anyway would leave
        // the caller believing it verified a specific build while both image
        // checks silently no-op, so refuse where the degraded input is visible.
        throw AttestationVerificationError(
            "trust release pins no image identity (none of image_digest, "
            + "accepted_image_digests, image_reference, accepted_image_references); "
            + "refusing to build a policy that would accept any Confidential Space workload"
        )
    }
    return policy
}

func b64urlDecode(_ base64URLEncoded: String) -> Data? {
    var base64 = base64URLEncoded
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let paddingLength = (4 - base64.count % 4) % 4
    base64.append(String(repeating: "=", count: paddingLength))
    return Data(base64Encoded: base64)
}

public func verifyGatewayAttestation(
    document: Data,
    policy: AttestationPolicy,
    nonceHex: String? = nil,
    tlsCertDer: Data? = nil,
    tlsExporter: Data? = nil,
    jwks: [String: Any]? = nil,
    jwksUrl: String = GCPJwksURI,
    urlSession: URLSession = .shared
) async throws -> GatewayAttestation {
    
    guard let text = String(data: document, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw AttestationVerificationError("Invalid JWT data")
    }
    let parts = text.split(separator: ".")
    if parts.count != 3 {
        throw AttestationVerificationError("expected 3 JWT segments, got \(parts.count)")
    }
    
    let hB64 = String(parts[0])
    let pB64 = String(parts[1])
    let sB64 = String(parts[2])
    
    guard let headerData = b64urlDecode(hB64),
          let payloadData = b64urlDecode(pB64),
          let signatureData = b64urlDecode(sB64) else {
        throw AttestationVerificationError("invalid JWT encoding")
    }
    
    guard let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
        throw AttestationVerificationError("invalid JWT JSON payload")
    }
    
    let signingInput = "\(hB64).\(pB64)".data(using: .utf8)!
    
    let activeJwks: [String: Any]
    if let jwks = jwks {
        activeJwks = jwks
    } else {
        if let reservedName = ClientTelemetry.reservedHeaderInSessionDefaults(urlSession) {
            throw reservedTelemetrySessionDefaultError(
                reservedName, entryPoint: "verifyGatewayAttestation"
            )
        }
        guard let url = URL(string: jwksUrl) else {
            throw AttestationVerificationError("Invalid JWKS URL")
        }
        let request = URLRequest(url: url)
        let (data, response) = try await urlSession.trustedRouterCredentialFreeCopy()
            .trustedRouterData(for: request)
        if let resp = response as? HTTPURLResponse,
           !(200..<300).contains(resp.statusCode) {
            throw AttestationVerificationError("JWKS fetch returned HTTP \(resp.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AttestationVerificationError("JWKS response is not JSON")
        }
        activeJwks = json
    }
    
    guard let keys = activeJwks["keys"] as? [[String: Any]] else {
        throw AttestationVerificationError("JWKS response missing keys array")
    }
    
    guard let alg = header["alg"] as? String, alg == "RS256" else {
        throw AttestationVerificationError("unsupported JWT alg; expected RS256")
    }
    
    guard let kid = header["kid"] as? String else {
        throw AttestationVerificationError("missing kid in header")
    }
    
    guard let jwk = keys.first(where: { ($0["kid"] as? String) == kid }) else {
        throw AttestationVerificationError("no JWK with kid=\(kid) in JWKS")
    }
    
    guard let kty = jwk["kty"] as? String, kty == "RSA" else {
        throw AttestationVerificationError("expected RSA key in JWKS")
    }
    
    // Real RS256 signature verification via Security.framework.
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    guard let nB64 = jwk["n"] as? String, let eB64 = jwk["e"] as? String,
          let nData = b64urlDecode(nB64), let eData = b64urlDecode(eB64) else {
        throw AttestationVerificationError("invalid JWK RSA parameters")
    }
    let pkcs1 = DER.rsaPublicKeyPKCS1(n: nData, e: eData)
    let attr: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1 as CFData, attr as CFDictionary, &error) else {
        throw AttestationVerificationError("failed to create public key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
    }
    guard SecKeyVerifySignature(
        key,
        .rsaSignatureMessagePKCS1v15SHA256,
        signingInput as CFData,
        signatureData as CFData,
        &error
    ) else {
        throw AttestationVerificationError("JWT signature verification failed")
    }
    #endif
    
    // Check claims
    return try checkClaims(claims: payload, policy: policy, nonceHex: nonceHex, tlsCertDer: tlsCertDer, tlsExporter: tlsExporter)
}

/// A caller-provided session cannot be allowed to default the SDK-reserved
/// telemetry field: URLSession merges these defaults after request assembly,
/// beyond the point where the SDK can strip them. Keep the refusal diagnostic
/// shared across the standalone trust/attestation entry points.
private func reservedTelemetrySessionDefaultError(
    _ reservedName: String,
    entryPoint: String
) -> TrustedRouterError {
    .internalError(
        "The URLSession passed to \(entryPoint) sets the SDK-reserved header "
        + "'\(reservedName)' in URLSessionConfiguration.httpAdditionalHeaders. "
        + "Remove it from httpAdditionalHeaders; x-tr-client may only be set "
        + "by the SDK's telemetry recorder."
    )
}

private func checkClaims(claims: [String: Any], policy: AttestationPolicy, nonceHex: String?, tlsCertDer: Data?, tlsExporter: Data?) throws -> GatewayAttestation {
    let now = Int(Date().timeIntervalSince1970)
    guard let exp = claims["exp"] as? Int else {
        throw AttestationVerificationError("JWT is missing a valid expiration")
    }
    if exp <= now {
        throw AttestationVerificationError("JWT expired at \(exp) (now=\(now))")
    }
    guard let iss = claims["iss"] as? String, iss == GCPIssuer else {
        let actual = claims["iss"] as? String ?? "missing"
        throw AttestationVerificationError("unexpected issuer \(actual); expected \(GCPIssuer)")
    }
    if !policy.allowDebug && (claims["dbgstat"] as? String)?.lowercased() != "disabled-since-boot" {
        throw AttestationVerificationError("debug Confidential Space workload must report disabled-since-boot")
    }
    if claims["swname"] as? String != "CONFIDENTIAL_SPACE" {
        throw AttestationVerificationError("attested workload is not running Confidential Space")
    }
    if claims["secboot"] as? Bool != true {
        throw AttestationVerificationError("attested workload does not report Secure Boot")
    }
    let hardware = claims["hwmodel"] as? String ?? "missing"
    if !["GCP_AMD_SEV", "GCP_AMD_SEV_ES", "GCP_INTEL_TDX"].contains(hardware) {
        throw AttestationVerificationError("unsupported confidential hardware model \(hardware)")
    }
    
    var audList: [String] = []
    if let audString = claims["aud"] as? String {
        audList.append(audString)
    } else if let audArr = claims["aud"] as? [String] {
        audList = audArr
    }
    if !audList.contains(policy.audience) {
        throw AttestationVerificationError("audience \(policy.audience) not in JWT aud \(audList)")
    }
    
    var imageDigest = ""
    var imageReference = ""
    if let submods = claims["submods"] as? [String: Any], let container = submods["container"] as? [String: Any] {
        imageDigest = container["image_digest"] as? String ?? ""
        imageReference = container["image_reference"] as? String ?? ""
    }
    
    guard policy.pinsImageIdentity else {
        // Defence in depth for hand-built policies: both image checks below are
        // guarded on a non-empty accepted list, so reaching them with nothing
        // pinned would accept any attested workload.
        throw AttestationVerificationError(
            "attestation policy pins no image identity; refusing to verify against a "
            + "policy that cannot distinguish the gateway from any other workload"
        )
    }
    let acceptedImageDigests = policy.imageDigests.isEmpty
        ? policy.imageDigest.map { [$0] } ?? []
        : policy.imageDigests
    if !acceptedImageDigests.isEmpty && !acceptedImageDigests.contains(imageDigest) {
        throw AttestationVerificationError("image_digest mismatch: workload=\(imageDigest), policy=\(acceptedImageDigests)")
    }
    let acceptedImageReferences = policy.imageReferences.isEmpty
        ? policy.imageReference.map { [$0] } ?? []
        : policy.imageReferences
    if !acceptedImageReferences.isEmpty && !acceptedImageReferences.contains(imageReference) {
        throw AttestationVerificationError("image_reference mismatch: workload=\(imageReference), policy=\(acceptedImageReferences)")
    }
    
    var nonces: [String] = []
    if let nString = claims["eat_nonce"] as? String {
        nonces.append(nString)
    } else if let nArr = claims["eat_nonce"] as? [String] {
        nonces.append(contentsOf: nArr)
    } else if let nString = claims["nonces"] as? String {
        nonces.append(nString)
    } else if let nArr = claims["nonces"] as? [String] {
        nonces.append(contentsOf: nArr)
    }
    
    var nonceMatch: String? = nil
    if let nonceHex = nonceHex {
        if !nonces.contains(where: { constantTimeEquals($0, nonceHex) }) {
            throw AttestationVerificationError("nonce \(nonceHex) not present in JWT nonces \(nonces)")
        }
        nonceMatch = nonceHex
    }

    if let tlsExporter = tlsExporter {
        guard let nonceHex = nonceHex else {
            throw AttestationVerificationError("fresh nonce required with exporter binding")
        }
        let exporterHex = tlsExporter.hexString
        // G6 relay closure is single-slot: the fresh nonce and the RFC 9266
        // TLS exporter must both be committed, and they must be distinct.
        if !nonces.contains(where: { constantTimeEquals($0, exporterHex) }) {
            throw AttestationVerificationError("TLS exporter not present in JWT nonces")
        }
        if constantTimeEquals(nonceHex, exporterHex) {
            throw AttestationVerificationError("fresh nonce must differ from TLS exporter binding")
        }
    }
    
    var certSha = claims["tls_cert_sha256"] as? String ?? claims["workload_tls_cert_sha256"] as? String
    
    #if canImport(CryptoKit)
    if certSha == nil, let tlsCertDer = tlsCertDer {
        let actual = SHA256.hash(data: tlsCertDer).compactMap { String(format: "%02x", $0) }.joined()
        for n in nonces {
            if n.lowercased() == actual {
                certSha = actual
                break
            }
        }
    }
    #endif
    
    guard let cSha = certSha, cSha.count == 64 else {
        throw AttestationVerificationError("JWT does not commit to a TLS cert SHA-256 — cannot bind connection")
    }
    let lowerCertSha = cSha.lowercased()
    
    #if canImport(CryptoKit)
    if let tlsCertDer = tlsCertDer {
        let actual = SHA256.hash(data: tlsCertDer).compactMap { String(format: "%02x", $0) }.joined()
        if actual != lowerCertSha {
            throw AttestationVerificationError("TLS cert mismatch: connection=\(actual), JWT=\(lowerCertSha)")
        }
    }
    #endif
    
    if let pCertSha = policy.certSha256?.lowercased(), lowerCertSha != pCertSha {
        throw AttestationVerificationError("JWT-committed cert SHA-256 doesn't match policy pin")
    }
    
    return GatewayAttestation(
        certSha256: lowerCertSha,
        imageDigest: imageDigest,
        imageReference: imageReference,
        nonce: nonceMatch,
        expiresAt: exp,
        issuer: iss,
        audience: policy.audience,
        rawClaims: claims.mapValues { SendableValue.from(any: $0) }
    )
}
