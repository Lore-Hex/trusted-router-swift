import Foundation
import CoreFoundation

func requireSignatureVerificationSupport() throws {
    throw AttestationVerificationError("RS256 signature verification requires Security on this platform")
}

func validateImageFields(_ object: [String: Any], lists: Bool = false) throws {
    for field in ["image_digest", "image_reference"] {
        if let value = object[field], !(value is String) {
            throw AttestationVerificationError("\(field) must be a string")
        }
    }
    if lists {
        for field in ["accepted_image_digests", "accepted_image_references"] {
            if let value = object[field], !(value is [String]) {
                throw AttestationVerificationError("\(field) must be an array of strings")
            }
        }
    }
}

func imageContainer(in claims: [String: Any]) throws -> [String: Any] {
    guard let rawSubmods = claims["submods"] else { return [:] }
    guard let submods = rawSubmods as? [String: Any] else {
        throw AttestationVerificationError("submods must be an object")
    }
    guard let rawContainer = submods["container"] else { return [:] }
    guard let container = rawContainer as? [String: Any] else {
        throw AttestationVerificationError("container must be an object")
    }
    try validateImageFields(container)
    return container
}

/// Foundation bridges NSNumber(1) to Bool; JSON trust claims must be real booleans.
func attestationBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
