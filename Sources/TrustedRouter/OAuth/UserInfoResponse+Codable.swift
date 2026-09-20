import Foundation

extension UserInfoResponse {
    /// Decodes this value from its wire representation.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        data = try values.decode(UserInfo.self, forKey: .data)
        additionalFields = try oauthAdditionalFields(from: decoder, knownKeys: CodingKeys.allCases)
    }

    /// Encodes this value using its wire field names.
    public func encode(to encoder: Encoder) throws {
        try additionalFields.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(data, forKey: .data)
    }
}
