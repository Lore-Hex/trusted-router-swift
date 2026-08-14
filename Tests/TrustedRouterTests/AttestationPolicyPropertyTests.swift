import XCTest
@testable import TrustedRouter

/// Property tests for the attestation policy boundary.
///
/// The law is a soundness statement about verification:
///
///     for every claims set K and policy P,
///         verification succeeds  =>  K's image identity was in P's accepted set
///
/// Before the non-vacuity guard this was false, and falsifiably so. Both image
/// checks are guarded on a non-empty accepted list:
///
///     if !acceptedImageDigests.isEmpty && !acceptedImageDigests.contains(imageDigest) {
///         throw AttestationVerificationError(...)
///     }
///
/// An EMPTY list short-circuits the `&&` to false and the throw is skipped, not
/// taken. And `policyFromTrustRelease` mapped a release with no image fields to
/// exactly that: a truncated body, an error page that parsed as JSON, or a
/// schema change produced a policy under which both checks silently no-op.
/// Verification then succeeded against any genuinely-attested Confidential
/// Space workload and returned a populated `GatewayAttestation` whose
/// `imageDigest` was the workload's own self-declared value — a success object
/// that reads as proof.
///
/// The vulnerable behaviour was previously enshrined in this suite:
/// `AttestationVerifyTests` verified with unpinned policies and asserted
/// success. Those fixtures now pin the digest their claims carry, so each still
/// reaches the check it targets.
///
/// Mirrors `tests/test_attestation_properties.py` in trusted-router-py and
/// `test/attestation-properties.test.js` in trusted-router-js.
final class AttestationPolicyPropertyTests: XCTestCase {

    /// The shapes a degraded HTTP response actually takes.
    private let absentStrings: [Any?] = [nil, "", "   "]
    private let absentLists: [Any?] = [nil, [String](), [""], ["", ""]]

    private func release(
        digest: Any?, digests: Any?, reference: Any?, references: Any?
    ) -> [String: Any] {
        var body: [String: Any] = [:]
        if let digest { body["image_digest"] = digest }
        if let digests { body["accepted_image_digests"] = digests }
        if let reference { body["image_reference"] = reference }
        if let references { body["accepted_image_references"] = references }
        return body
    }

    // MARK: - non-vacuity

    func testAPolicyIsEitherRefusedOrPinsImageIdentity() async throws {
        // The exhaustive product of every "absent" shape. Each combination is a
        // degraded release the builder used to turn into an unpinned policy.
        for digest in absentStrings {
            for digests in absentLists {
                for reference in absentStrings {
                    for references in absentLists {
                        let body = release(
                            digest: digest, digests: digests,
                            reference: reference, references: references)
                        do {
                            let policy = try await policyFromTrustRelease(release: body)
                            XCTAssertTrue(
                                policy.pinsImageIdentity,
                                "built an unpinned policy from \(body)")
                        } catch let error as AttestationVerificationError {
                            XCTAssertTrue(
                                "\(error)".contains("pins no image identity"),
                                "unexpected error for \(body): \(error)")
                        }
                    }
                }
            }
        }
    }

    func testAnEmptyReleaseIsRefused() async {
        do {
            _ = try await policyFromTrustRelease(release: [:])
            XCTFail("an empty trust release must be refused")
        } catch let error as AttestationVerificationError {
            XCTAssertTrue("\(error)".contains("pins no image identity"), "\(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAReleaseWhoseListsHoldNoUsableStringsIsRefused() async {
        // The builder filters empty strings out of the published lists, so this
        // collapses to the empty-set case rather than pinning junk.
        do {
            _ = try await policyFromTrustRelease(
                release: ["accepted_image_digests": ["", ""],
                          "accepted_image_references": [""]])
            XCTFail("a release with no usable pins must be refused")
        } catch let error as AttestationVerificationError {
            XCTAssertTrue("\(error)".contains("pins no image identity"), "\(error)")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testAReleaseWithOnlyOneIdentityKindIsAccepted() async throws {
        // Non-vacuity requires one of the two, not both.
        let policy = try await policyFromTrustRelease(release: ["image_digest": "sha256:beef"])

        XCTAssertTrue(policy.pinsImageIdentity)
        XCTAssertEqual(policy.imageDigests, ["sha256:beef"])
        XCTAssertTrue(policy.imageReferences.isEmpty)
    }

    func testADefaultPolicyPinsNothing() {
        // The state verification must refuse. Pinned explicitly so a future
        // change cannot quietly make an unpinned policy look acceptable.
        XCTAssertFalse(AttestationPolicy().pinsImageIdentity)
    }

    func testACertOnlyPolicyPinsNothing() {
        let policy = AttestationPolicy(certSha256: String(repeating: "a", count: 64))
        XCTAssertFalse(
            policy.pinsImageIdentity,
            "pinning the TLS cert alone says nothing about which build answered")
    }

    // MARK: - the guard agrees with what it guards

    func testPinsImageIdentityAgreesWithTheChecksItGuards() {
        let values: [String?] = [nil, "", "x"]
        let lists: [[String]] = [[], ["y"]]

        for digest in values {
            for digests in lists {
                for reference in values {
                    for references in lists {
                        let policy = AttestationPolicy(
                            imageDigest: digest,
                            imageDigests: digests,
                            imageReference: reference,
                            imageReferences: references)

                        // Mirrors the two conditions that build the accepted
                        // lists in verifyGatewayAttestation. If the guard and
                        // the checks ever drift apart, the hole reopens.
                        let acceptedDigests = policy.imageDigests.isEmpty
                            ? policy.imageDigest.map { [$0] } ?? []
                            : policy.imageDigests
                        let acceptedReferences = policy.imageReferences.isEmpty
                            ? policy.imageReference.map { [$0] } ?? []
                            : policy.imageReferences
                        let digestCheckRuns = !acceptedDigests.filter { !$0.isEmpty }.isEmpty
                        let referenceCheckRuns = !acceptedReferences.filter { !$0.isEmpty }.isEmpty

                        XCTAssertEqual(
                            policy.pinsImageIdentity,
                            digestCheckRuns || referenceCheckRuns,
                            "guard disagrees with the checks it guards for \(policy)")
                    }
                }
            }
        }
    }
}
