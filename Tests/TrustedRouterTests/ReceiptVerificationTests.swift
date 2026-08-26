import XCTest
@testable import TrustedRouter

#if canImport(CryptoKit)
import CryptoKit

final class ReceiptVerificationTests: XCTestCase {
    private let fixedNow: TimeInterval = 1_756_224_060
    private let requestBody = Data("request".utf8)
    private let responseBody = Data("response".utf8)

    func testFrozenParityFixturesVerifyWithoutModification() async throws {
        for name in ["compact-body", "chat-stream", "responses-stream"] {
            let directory = try fixtureDirectory(name)
            let receipt = try Data(contentsOf: directory.appendingPathComponent("receipt.jws"))
            let request = try Data(contentsOf: directory.appendingPathComponent("request.body"))
            let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
            let metadata = try JSONDecoder().decode(FixtureMetadata.self, from: metadataData)
            var options = ReceiptVerificationOptions(
                requestBody: request,
                expectedNonce: metadata.expectedNonce,
                now: metadata.now,
                requireAttestation: metadata.requireAttestation
            )
            let response = directory.appendingPathComponent("response.body")
            let stream = directory.appendingPathComponent("response.sse")
            if FileManager.default.fileExists(atPath: response.path) {
                options.responseBody = try Data(contentsOf: response)
            } else {
                options.responseStream = try Data(contentsOf: stream)
            }

            // Frozen streaming vectors contain signed placeholder evidence.
            // Production calls always use verifyReceiptKeyAttestation instead.
            let verified = try await verifyReceipt(
                receipt,
                options: options,
                gcpAttestationVerifier: { _, _ in }
            )
            XCTAssertEqual(verified.rv, 1, name)
            XCTAssertEqual(verified.nonce, metadata.expectedNonce, name)
        }
    }

    func testCompactReceiptVerifiesExactBodies() async throws {
        let generated = try makeReceipt(claims: baseClaims())
        let verified = try await verifyReceipt(
            generated.raw,
            options: ReceiptVerificationOptions(
                requestBody: requestBody,
                responseBody: responseBody,
                expectedNonce: "nonce_test",
                maxAgeSeconds: 10,
                now: fixedNow,
                requireAttestation: false
            )
        )
        XCTAssertEqual(verified.model.provider, "provider")
        XCTAssertEqual(verified.attestationStatus, .unverifiedByThisSDK)
        XCTAssertEqual(verified.attestation, verified.attestationStatus)
    }

    func testFlippedPayloadByteFailsSignature() async throws {
        let generated = try makeReceipt(claims: baseClaims())
        var payload = try decodeSegment(generated.envelope.payload)
        payload[payload.index(before: payload.endIndex)] ^= 1
        let tampered = compact(
            protected: generated.envelope.protected,
            payload: encode(payload),
            signature: generated.envelope.signature
        )
        await assertReceiptError(ReceiptSignatureError.self) {
            _ = try await self.verifyWithoutAttestation(tampered)
        }
    }

    func testWrongSigningKeyFailsSignature() async throws {
        let generated = try makeReceipt(
            claims: baseClaims(),
            signingKey: Curve25519.Signing.PrivateKey()
        )
        await assertReceiptError(ReceiptSignatureError.self) {
            _ = try await self.verifyWithoutAttestation(generated.raw)
        }
    }

    func testEditedClaimWithStaleSignatureFailsSignature() async throws {
        let generated = try makeReceipt(claims: baseClaims())
        var claims = try XCTUnwrap(
            JSONSerialization.jsonObject(with: decodeSegment(generated.envelope.payload))
                as? [String: Any]
        )
        var model = try XCTUnwrap(claims["model"] as? [String: Any])
        model["selected"] = "tampered"
        claims["model"] = model
        let editedPayload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let tampered = compact(
            protected: generated.envelope.protected,
            payload: encode(editedPayload),
            signature: generated.envelope.signature
        )
        await assertReceiptError(ReceiptSignatureError.self) {
            _ = try await self.verifyWithoutAttestation(tampered)
        }
    }

    func testWrongKidFailsHeaderBeforeSignature() async throws {
        let generated = try makeReceipt(
            claims: baseClaims(),
            headerUpdates: ["kid": encode(hash(Data("wrong".utf8)))]
        )
        await assertReceiptError(ReceiptHeaderError.self) {
            _ = try await self.verifyWithoutAttestation(generated.raw)
        }
    }

    func testStreamByteFlipFailsHash() async throws {
        let generated = try makeStreamReceipt()
        var tampered = generated.stream
        let range = try XCTUnwrap(tampered.range(of: Data("hello".utf8)))
        tampered[range.lowerBound] = 0x6a
        await assertReceiptError(ReceiptHashError.self) {
            _ = try await self.verifyStream(generated.receipt.raw, stream: tampered)
        }
    }

    func testReceiptMustBeLastBeforeDone() async throws {
        let generated = try makeStreamReceipt()
        let extra = Data("data: {\"choices\":[]}\n\n".utf8)
        let tampered = generated.dataEvent + generated.receiptEvent + extra + generated.doneEvent
        await assertReceiptError(ReceiptHashError.self) {
            _ = try await self.verifyStream(generated.receipt.raw, stream: tampered)
        }
    }

    func testStreamEventsOffByOneFails() async throws {
        let generated = try makeStreamReceipt(eventsClaim: 2)
        await assertReceiptError(ReceiptHashError.self) {
            _ = try await self.verifyStream(generated.receipt.raw, stream: generated.stream)
        }
    }

    func testFutureIatBeyondSkewFails() async throws {
        var claims = baseClaims()
        claims["iat"] = Int(fixedNow) + 61
        let generated = try makeReceipt(claims: claims)
        await assertReceiptError(ReceiptTimeError.self) {
            _ = try await self.verifyWithoutAttestation(generated.raw)
        }
    }

    func testMaxAgeRejectsOldReceipt() async throws {
        let generated = try makeReceipt(claims: baseClaims())
        await assertReceiptError(ReceiptTimeError.self) {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(
                    maxAgeSeconds: 0.5,
                    now: self.fixedNow,
                    requireAttestation: false
                )
            )
        }
    }

    func testExpiredTeeVerifiedWindowFails() async throws {
        var claims = baseClaims()
        var upstream = try XCTUnwrap(claims["upstream"] as? [String: Any])
        upstream["verification_expires_at"] = Int(fixedNow) - 1
        claims["upstream"] = upstream
        let generated = try makeReceipt(claims: claims)
        await assertReceiptError(ReceiptUpstreamError.self) {
            _ = try await self.verifyWithoutAttestation(generated.raw)
        }
    }

    func testNonceMismatchFails() async throws {
        let generated = try makeReceipt(claims: baseClaims())
        await assertReceiptError(ReceiptNonceError.self) {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(
                    expectedNonce: "different", now: self.fixedNow, requireAttestation: false
                )
            )
        }
    }

    func testUnsupportedAttestationKindFailsClosed() async throws {
        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        let generated = try makeReceipt(
            claims: claims,
            flattened: true,
            headerUpdates: ["att_kind": "aws-nitro-cose"]
        )
        await assertReceiptError(UnsupportedAttestationError.self) {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(now: self.fixedNow, requireAttestation: false),
                gcpAttestationVerifier: { _, _ in }
            )
        }
    }

    func testGCPAttestationChainsWithDomainSeparatedKeyCommitment() async throws {
        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        let generated = try makeReceipt(claims: claims, flattened: true)
        let recorder = CommitmentRecorder()
        let verified = try await verifyReceipt(
            generated.raw,
            options: ReceiptVerificationOptions(now: fixedNow, requireAttestation: false),
            gcpAttestationVerifier: { document, commitment in
                recorder.record(document: document, commitment: commitment)
            }
        )
        let expected = hash(Data("inference-receipt-key-v1\0".utf8) + generated.publicKey)
        XCTAssertEqual(recorder.document, Data("fixture.jwt.placeholder".utf8))
        XCTAssertEqual(recorder.commitment, expected)
        XCTAssertEqual(verified.attestationStatus, .verified)
    }

    func testReceiptKeyBindingAcceptsNonceSetMembershipButLiveBindingRejectsIt() async throws {
        let policy = AttestationPolicy(imageDigest: "sha256:abc123")
        for commitmentPosition in [0, 2] {
            let key = Curve25519.Signing.PrivateKey()
            let commitment = hash(keyCommitmentTestDomain + key.publicKey.rawRepresentation)
            var nonces = [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
            nonces.insert(commitment.hexString, at: commitmentPosition)
            let document = try gcpKeyAttestation(nonces: nonces)
            var claims = baseClaims()
            claims.removeValue(forKey: "att_sha256")
            let generated = try makeReceipt(
                claims: claims,
                flattened: true,
                headerUpdates: ["att": try XCTUnwrap(String(data: document, encoding: .ascii))],
                key: key
            )

            let verified = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(now: fixedNow),
                gcpAttestationVerifier: mockedReceiptKeyVerifier(policy: policy)
            )
            XCTAssertEqual(verified.attestationStatus, .verified)

            do {
                _ = try await verifyGatewayAttestation(
                    document: document,
                    policy: policy,
                    jwks: [:],
                    signatureVerifier: mockedAttestationSignature
                )
                XCTFail("expected live-channel TLS certificate binding failure")
            } catch let error as AttestationVerificationError {
                XCTAssertTrue(error.message.contains("TLS cert"), error.message)
            }
        }
    }

    func testReceiptKeyBindingRejectsWrongCommitment() async throws {
        let policy = AttestationPolicy(imageDigest: "sha256:abc123")
        let document = try gcpKeyAttestation(nonces: [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            String(repeating: "c", count: 64),
        ])
        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        let generated = try makeReceipt(
            claims: claims,
            flattened: true,
            headerUpdates: ["att": try XCTUnwrap(String(data: document, encoding: .ascii))]
        )

        do {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(now: fixedNow),
                gcpAttestationVerifier: mockedReceiptKeyVerifier(policy: policy)
            )
            XCTFail("expected receipt key commitment failure")
        } catch let error as ReceiptAttestationError {
            XCTAssertTrue(error.message.contains("not present in JWT nonces"), error.message)
        }
    }

    func testCompactReceiptVerifiesSuppliedPinnedAttestation() async throws {
        let policy = AttestationPolicy(imageDigest: "sha256:abc123")
        let key = Curve25519.Signing.PrivateKey()
        let commitment = hash(keyCommitmentTestDomain + key.publicKey.rawRepresentation)
        let document = try gcpKeyAttestation(nonces: [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            commitment.hexString,
        ])
        var claims = baseClaims()
        claims["att_sha256"] = encode(hash(document))
        let generated = try makeReceipt(claims: claims, key: key)

        let verified = try await verifyReceipt(
            generated.raw,
            options: ReceiptVerificationOptions(now: fixedNow, attestation: document),
            gcpAttestationVerifier: mockedReceiptKeyVerifier(policy: policy)
        )
        XCTAssertEqual(verified.attestationStatus, .verified)

        var changed = document
        changed[changed.index(before: changed.endIndex)] ^= 1
        do {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(now: fixedNow, attestation: changed),
                gcpAttestationVerifier: mockedReceiptKeyVerifier(policy: policy)
            )
            XCTFail("expected compact attestation digest failure")
        } catch let error as ReceiptAttestationError {
            XCTAssertTrue(error.message.contains("att_sha256 check failed"), error.message)
        }
    }

    func testFlattenedReceiptRejectsMismatchedSuppliedAttestation() async throws {
        let document = try gcpKeyAttestation(nonces: [String(repeating: "a", count: 64)])
        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        let generated = try makeReceipt(
            claims: claims,
            flattened: true,
            headerUpdates: ["att": try XCTUnwrap(String(data: document, encoding: .ascii))]
        )

        do {
            _ = try await verifyReceipt(
                generated.raw,
                options: ReceiptVerificationOptions(
                    now: fixedNow,
                    attestation: document + Data("x".utf8)
                ),
                gcpAttestationVerifier: { _, _ in }
            )
            XCTFail("expected flattened attestation mismatch")
        } catch let error as ReceiptAttestationError {
            XCTAssertTrue(error.message.contains("does not match"), error.message)
            XCTAssertTrue(error.message.contains("embedded attestation"), error.message)
        }
    }

    func testMissingAttestationRaisesByDefault() async throws {
        let compactReceipt = try makeReceipt(claims: baseClaims())
        await assertReceiptError(MissingAttestationError.self) {
            _ = try await verifyReceipt(
                compactReceipt.raw,
                options: ReceiptVerificationOptions(now: self.fixedNow)
            )
        }

        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        let flattened = try makeReceipt(
            claims: claims, flattened: true, embedAttestation: false
        )
        await assertReceiptError(MissingAttestationError.self) {
            _ = try await verifyReceipt(
                flattened.raw,
                options: ReceiptVerificationOptions(now: self.fixedNow, requireAttestation: false),
                gcpAttestationVerifier: { _, _ in }
            )
        }
    }

    func testDuplicateJSONMemberAtNestedDepthIsRejected() async throws {
        let claimsData = try JSONSerialization.data(withJSONObject: baseClaims(), options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: claimsData, encoding: .utf8))
        let duplicate = text.replacingOccurrences(
            of: "\"selected\":\"selected\"",
            with: "\"selected\":\"selected\",\"selected\":\"selected\""
        )
        XCTAssertNotEqual(text, duplicate)
        let generated = try makeReceipt(payload: Data(duplicate.utf8))
        await assertReceiptError(ReceiptStructureError.self) {
            _ = try await self.verifyWithoutAttestation(generated.raw)
        }
    }

    func testStrictStreamRejectsMultilineDataAndUnknownFields() async throws {
        let generated = try makeStreamReceipt()
        let multiline = Data("data: {\"delta\":\"hel\"}\ndata: {\"delta\":\"lo\"}\n\n".utf8)
            + generated.receiptEvent + generated.doneEvent
        await assertReceiptError(ReceiptHashError.self) {
            _ = try await self.verifyStream(generated.receipt.raw, stream: multiline)
        }

        let unknown = Data("id: 1\ndata: {\"delta\":\"hello\"}\n\n".utf8)
            + generated.receiptEvent + generated.doneEvent
        await assertReceiptError(ReceiptHashError.self) {
            _ = try await self.verifyStream(generated.receipt.raw, stream: unknown)
        }
    }

    func testReceiptCapturePreservesWireAndVerifies() async throws {
        let generated = try makeStreamReceipt()
        let source = TrustedRouterByteStream { continuation in
            for byte in generated.stream { continuation.yield(byte) }
            continuation.finish()
        }
        let capture = ReceiptCapture(source: source)
        var forwarded = Data()
        for try await byte in capture.stream() {
            forwarded.append(byte)
        }
        XCTAssertEqual(forwarded, generated.stream)
        XCTAssertEqual(capture.capturedBytes, generated.stream)
        XCTAssertEqual(capture.receipt, generated.receipt.envelope)
        let verified = try await capture.verify(
            options: ReceiptVerificationOptions(now: fixedNow),
            gcpAttestationVerifier: { _, _ in }
        )
        XCTAssertEqual(verified.jti, "chatcmpl-test")
    }

    private func verifyWithoutAttestation(_ receipt: Data) async throws -> ReceiptClaims {
        try await verifyReceipt(
            receipt,
            options: ReceiptVerificationOptions(now: fixedNow, requireAttestation: false)
        )
    }

    private func verifyStream(_ receipt: Data, stream: Data) async throws -> ReceiptClaims {
        try await verifyReceipt(
            receipt,
            options: ReceiptVerificationOptions(responseStream: stream, now: fixedNow),
            gcpAttestationVerifier: { _, _ in }
        )
    }

    private func baseClaims() -> [String: Any] {
        [
            "rv": 1,
            "iss": "https://api.trustedrouter.com",
            "iat": Int(fixedNow) - 1,
            "jti": "chatcmpl-test",
            "nonce": "nonce_test",
            "route": "chat.completions",
            "req": ["alg": "sha256", "hash": encode(hash(requestBody)), "of": "body"],
            "resp": ["alg": "sha256", "hash": encode(hash(responseBody)), "of": "body"],
            "model": [
                "requested": "requested", "selected": "selected",
                "provider": "provider", "endpoint": "endpoint",
            ],
            "upstream": [
                "tier": "tee-verified", "policy": "chutes-tdx-nvidia-e2e-v1",
                "verified_at": Int(fixedNow) - 60,
                "verification_expires_at": Int(fixedNow) + 60,
            ],
            "att_sha256": encode(hash(Data("attestation".utf8))),
        ]
    }

    private var keyCommitmentTestDomain: Data {
        Data("inference-receipt-key-v1\0".utf8)
    }

    private var mockedAttestationSignature: AttestationSignatureVerifier {
        { _, _, _, _ in }
    }

    private func mockedReceiptKeyVerifier(
        policy: AttestationPolicy
    ) -> ReceiptGCPAttestationVerifier {
        let signatureVerifier = mockedAttestationSignature
        return { document, commitment in
            try await verifyReceiptKeyAttestation(
                document: document,
                policy: policy,
                keyCommitmentHex: commitment.hexString,
                jwks: [:],
                signatureVerifier: signatureVerifier
            )
        }
    }

    private func gcpKeyAttestation(nonces: [String]) throws -> Data {
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "RS256",
            "kid": "test-kid",
        ], options: [.sortedKeys])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": GCPIssuer,
            "aud": ["quill-cloud"],
            "exp": 4_000_000_000,
            "dbgstat": "disabled-since-boot",
            "swname": "CONFIDENTIAL_SPACE",
            "secboot": true,
            "hwmodel": "GCP_AMD_SEV",
            "submods": [
                "container": [
                    "image_digest": "sha256:abc123",
                    "image_reference": "registry.example/image:tag",
                ],
            ],
            "eat_nonce": nonces,
        ], options: [.sortedKeys])
        return Data("\(encode(header)).\(encode(claims)).\(encode(Data("fake-signature".utf8)))".utf8)
    }

    private func makeStreamReceipt(eventsClaim: Int = 1) throws -> GeneratedStream {
        let payload = Data("{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}".utf8)
        var claims = baseClaims()
        claims.removeValue(forKey: "att_sha256")
        claims["resp"] = [
            "alg": "sha256",
            "hash": encode(hash(payload + Data([0x0a]))),
            "of": "sse-data-v1",
            "events": eventsClaim,
        ]
        let receipt = try makeReceipt(claims: claims, flattened: true)
        let receiptObject = try JSONSerialization.jsonObject(with: receipt.raw)
        let wrapper: [String: Any] = [
            "object": "chat.completion.chunk",
            "choices": [],
            "inference_receipt": receiptObject,
        ]
        let wrapperData = try JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys])
        let dataEvent = Data("data: ".utf8) + payload + Data("\n\n".utf8)
        let receiptEvent = Data("data: ".utf8) + wrapperData + Data("\n\n".utf8)
        let doneEvent = Data("data: [DONE]\n\n".utf8)
        return GeneratedStream(
            receipt: receipt,
            dataEvent: dataEvent,
            receiptEvent: receiptEvent,
            doneEvent: doneEvent
        )
    }

    private func makeReceipt(
        claims: [String: Any],
        flattened: Bool = false,
        embedAttestation: Bool = true,
        headerUpdates: [String: Any] = [:],
        key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> GeneratedReceipt {
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return try makeReceipt(
            payload: payload,
            flattened: flattened,
            embedAttestation: embedAttestation,
            headerUpdates: headerUpdates,
            key: key,
            signingKey: signingKey
        )
    }

    private func makeReceipt(
        payload: Data,
        flattened: Bool = false,
        embedAttestation: Bool = true,
        headerUpdates: [String: Any] = [:],
        key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> GeneratedReceipt {
        let publicKey = key.publicKey.rawRepresentation
        var header: [String: Any] = [
            "alg": "EdDSA",
            "typ": "inference-receipt+jws",
            "kid": encode(hash(publicKey)),
            "jwk": ["kty": "OKP", "crv": "Ed25519", "x": encode(publicKey)],
        ]
        if flattened && embedAttestation {
            header["att"] = "fixture.jwt.placeholder"
            header["att_kind"] = "gcp-cs-jwt"
        }
        for (key, value) in headerUpdates { header[key] = value }
        let protectedData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let protected = encode(protectedData)
        let payloadSegment = encode(payload)
        let signature = try (signingKey ?? key).signature(
            for: Data("\(protected).\(payloadSegment)".utf8)
        )
        let envelope = FlattenedReceiptJWS(
            protected: protected, payload: payloadSegment, signature: encode(signature)
        )
        let raw: Data
        if flattened {
            raw = try JSONSerialization.data(withJSONObject: [
                "protected": envelope.protected,
                "payload": envelope.payload,
                "signature": envelope.signature,
            ], options: [.sortedKeys])
        } else {
            raw = compact(
                protected: envelope.protected,
                payload: envelope.payload,
                signature: envelope.signature
            )
        }
        return GeneratedReceipt(raw: raw, envelope: envelope, publicKey: publicKey)
    }

    private func fixtureDirectory(_ name: String) throws -> URL {
        let root = try XCTUnwrap(Bundle.module.resourceURL)
        let directory = root.appendingPathComponent("receipts").appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.path)
        return directory
    }

    private func assertReceiptError<T: ReceiptVerificationError>(
        _ type: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(type)", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error is T,
                "expected \(type), got \(Swift.type(of: error)): \(error)",
                file: file,
                line: line
            )
        }
    }

    private func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeSegment(_ value: String) throws -> Data {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: base64))
    }

    private func compact(protected: String, payload: String, signature: String) -> Data {
        Data("\(protected).\(payload).\(signature)".utf8)
    }
}

private struct FixtureMetadata: Decodable {
    let expectedNonce: String
    let requireAttestation: Bool
    let now: TimeInterval

    enum CodingKeys: String, CodingKey {
        case expectedNonce = "expected_nonce"
        case requireAttestation = "require_attestation"
        case now
    }
}

private struct GeneratedReceipt {
    let raw: Data
    let envelope: FlattenedReceiptJWS
    let publicKey: Data
}

private struct GeneratedStream {
    let receipt: GeneratedReceipt
    let dataEvent: Data
    let receiptEvent: Data
    let doneEvent: Data
    var stream: Data { dataEvent + receiptEvent + doneEvent }
}

private final class CommitmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedDocument: Data?
    private var savedCommitment: Data?

    var document: Data? {
        lock.lock()
        defer { lock.unlock() }
        return savedDocument
    }

    var commitment: Data? {
        lock.lock()
        defer { lock.unlock() }
        return savedCommitment
    }

    func record(document: Data, commitment: Data) {
        lock.lock()
        defer { lock.unlock() }
        savedDocument = document
        savedCommitment = commitment
    }
}

#else

final class ReceiptVerificationTests: XCTestCase {
    func testReceiptVerificationRequiresCryptoKit() throws {
        throw XCTSkip("Receipt verification uses CryptoKit.Curve25519.Signing on Apple platforms")
    }
}

#endif
