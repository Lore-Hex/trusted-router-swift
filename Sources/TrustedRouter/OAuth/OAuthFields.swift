import Foundation

func oauthAdditionalFields<Key: CodingKey>(from decoder: Decoder, knownKeys: [Key]) throws -> [String: JSONValue] {
    let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
    let known = Set(knownKeys.map(\.stringValue))
    return object.filter { !known.contains($0.key) }
}
