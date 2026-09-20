import Foundation

// MARK: - OAuth models

/// A sourced, exact verified-email domain match, not proof of employment or endorsement.
public struct CompanyAffiliation: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    public var companyName: String
    public var fundingOrganization: String
    public var relationship: String
    public var domain: String
    public var foundingYear: Int?
    public var sourceURL: String
    public var checkedAt: String
    public var matchMethod: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case relationship, domain
        case companyName = "company_name"
        case fundingOrganization = "funding_organization"
        case foundingYear = "founding_year"
        case sourceURL = "source_url"
        case checkedAt = "checked_at"
        case matchMethod = "match_method"
    }

    public init(
        companyName: String, fundingOrganization: String, relationship: String,
        domain: String, foundingYear: Int? = nil, sourceURL: String,
        checkedAt: String, matchMethod: String
    ) {
        self.companyName = companyName
        self.fundingOrganization = fundingOrganization
        self.relationship = relationship
        self.domain = domain
        self.foundingYear = foundingYear
        self.sourceURL = sourceURL
        self.checkedAt = checkedAt
        self.matchMethod = matchMethod
    }
}

/// Verified identity attached to a delegated key, as returned by
/// `/auth/keys` (`identity`) and embedded in `/auth/userinfo`.
public struct OAuthIdentity: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    public var sub: String
    public var email: String?
    public var emailVerified: Bool?
    public var walletAddress: String?
    public var companyAffiliations: [CompanyAffiliation]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sub, email
        case emailVerified = "email_verified"
        case walletAddress = "wallet_address"
        case companyAffiliations = "company_affiliations"
    }

    public init(
        sub: String,
        email: String? = nil,
        emailVerified: Bool? = nil,
        walletAddress: String? = nil,
        companyAffiliations: [CompanyAffiliation]? = nil
    ) {
        self.sub = sub
        self.email = email
        self.emailVerified = emailVerified
        self.walletAddress = walletAddress
        self.companyAffiliations = companyAffiliations
    }
}

/// Result of exchanging an authorization `code` for a delegated key.
/// Mirrors the `/auth/keys` response: `{ key, user_id, identity, data }`.
public struct OAuthToken: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    /// The delegated key, e.g. `"sk-tr-v1-..."`. Use as the Bearer token for
    /// subsequent gateway calls (including `/auth/userinfo`).
    public var key: String
    /// The owning user id, when the backend includes one.
    public var userId: String?
    /// Verified identity (`sub`/`email`/…), or `nil` for anonymous keys.
    public var identity: OAuthIdentity?
    /// Optional opaque key metadata; absent in the minimal producer response.
    public var data: [String: JSONValue]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case userId = "user_id"
        case identity
        case data
    }

    public init(key: String, userId: String? = nil, identity: OAuthIdentity? = nil) {
        self.key = key
        self.userId = userId
        self.identity = identity
    }
}

/// The `data` payload returned by `GET /auth/userinfo`.
public struct UserInfo: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    public var sub: String?
    public var email: String?
    public var emailVerified: Bool?
    public var walletAddress: String?
    public var workspaceId: String?
    /// ISO-8601 creation timestamp string (the backend returns a string here,
    /// not an epoch number).
    public var createdAt: String?
    public var companyAffiliations: [CompanyAffiliation]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sub, email
        case emailVerified = "email_verified"
        case walletAddress = "wallet_address"
        case workspaceId = "workspace_id"
        case createdAt = "created_at"
        case companyAffiliations = "company_affiliations"
    }

    public init(
        sub: String?,
        email: String? = nil,
        emailVerified: Bool? = nil,
        walletAddress: String? = nil,
        workspaceId: String? = nil,
        createdAt: String? = nil,
        companyAffiliations: [CompanyAffiliation]? = nil
    ) {
        self.sub = sub
        self.email = email
        self.emailVerified = emailVerified
        self.walletAddress = walletAddress
        self.workspaceId = workspaceId
        self.createdAt = createdAt
        self.companyAffiliations = companyAffiliations
    }
}

/// Envelope for `GET /auth/userinfo`: `{ "data": { ... } }`.
public struct UserInfoResponse: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable { case data }
    public var data: UserInfo
    public init(data: UserInfo) { self.data = data }
}
