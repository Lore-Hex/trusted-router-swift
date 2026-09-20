import Foundation

extension OAuthToken {
    /// Decodes this value from its wire representation.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        userId = try values.decodeIfPresent(String.self, forKey: .userId)
        identity = try values.decodeIfPresent(OAuthIdentity.self, forKey: .identity)
        data = try values.decodeIfPresent([String: JSONValue].self, forKey: .data)
        additionalFields = try oauthAdditionalFields(from: decoder, knownKeys: CodingKeys.allCases)
    }

    /// Encodes this value using its wire field names.
    public func encode(to encoder: Encoder) throws {
        try additionalFields.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        try values.encodeIfPresent(userId, forKey: .userId)
        try values.encodeIfPresent(identity, forKey: .identity)
        try values.encodeIfPresent(data, forKey: .data)
    }
}
