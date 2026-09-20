import Foundation

extension CompanyAffiliation {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        companyName = try values.decode(String.self, forKey: .companyName)
        fundingOrganization = try values.decode(String.self, forKey: .fundingOrganization)
        relationship = try values.decode(String.self, forKey: .relationship)
        domain = try values.decode(String.self, forKey: .domain)
        foundingYear = try values.decodeIfPresent(Int.self, forKey: .foundingYear)
        sourceURL = try values.decode(String.self, forKey: .sourceURL)
        checkedAt = try values.decode(String.self, forKey: .checkedAt)
        matchMethod = try values.decode(String.self, forKey: .matchMethod)
        additionalFields = try oauthAdditionalFields(from: decoder, knownKeys: CodingKeys.allCases)
    }

    public func encode(to encoder: Encoder) throws {
        try additionalFields.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(companyName, forKey: .companyName)
        try values.encode(fundingOrganization, forKey: .fundingOrganization)
        try values.encode(relationship, forKey: .relationship)
        try values.encode(domain, forKey: .domain)
        try values.encodeIfPresent(foundingYear, forKey: .foundingYear)
        try values.encode(sourceURL, forKey: .sourceURL)
        try values.encode(checkedAt, forKey: .checkedAt)
        try values.encode(matchMethod, forKey: .matchMethod)
    }
}
