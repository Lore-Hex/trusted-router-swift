import Foundation

extension UserInfo {
    /// Decodes this value from its wire representation.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sub = try values.decodeIfPresent(String.self, forKey: .sub)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        emailVerified = try values.decodeIfPresent(Bool.self, forKey: .emailVerified)
        walletAddress = try values.decodeIfPresent(String.self, forKey: .walletAddress)
        workspaceId = try values.decodeIfPresent(String.self, forKey: .workspaceId)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        companyAffiliations = try values.decodeIfPresent([CompanyAffiliation].self, forKey: .companyAffiliations)
        additionalFields = try oauthAdditionalFields(from: decoder, knownKeys: CodingKeys.allCases)
    }

    /// Encodes this value using its wire field names.
    public func encode(to encoder: Encoder) throws {
        try additionalFields.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(sub, forKey: .sub)
        try values.encodeIfPresent(email, forKey: .email)
        try values.encodeIfPresent(emailVerified, forKey: .emailVerified)
        try values.encodeIfPresent(walletAddress, forKey: .walletAddress)
        try values.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try values.encodeIfPresent(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(companyAffiliations, forKey: .companyAffiliations)
    }
}
