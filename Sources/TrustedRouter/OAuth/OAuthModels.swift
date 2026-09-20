import Foundation

// MARK: - OAuth models

/// A sourced, exact verified-email domain match, not proof of employment or endorsement.
public struct CompanyAffiliation: Codable, Sendable, Equatable {
    /// Unknown producer fields retained without imposing a schema.
    public var additionalFields: [String: JSONValue] = [:]

    /// Company matched by the verified email domain.
    public var companyName: String
    /// Funding organization associated with the company.
    public var fundingOrganization: String
    /// Relationship described by the affiliation evidence.
    public var relationship: String
    /// Verified email domain used for the match.
    public var domain: String
    /// Company founding year, when known.
    public var foundingYear: Int?
    /// URL of the evidence supporting the affiliation.
    public var sourceURL: String
    /// Timestamp when the affiliation evidence was checked.
    public var checkedAt: String
    /// Method used to match the identity to the company.
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

    /// Creates a `CompanyAffiliation` with the supplied values.
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

    /// Subject identifier reported by the identity issuer.
    public var sub: String
    /// Email address associated with the identity.
    public var email: String?
    /// Whether the issuer reports the email as verified.
    public var emailVerified: Bool?
    /// Wallet address associated with the identity.
    public var walletAddress: String?
    /// Sourced verified-email domain matches; these do not prove employment.
    public var companyAffiliations: [CompanyAffiliation]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sub, email
        case emailVerified = "email_verified"
        case walletAddress = "wallet_address"
        case companyAffiliations = "company_affiliations"
    }

    /// Creates an `OAuthIdentity` with the supplied values.
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

    /// Creates an `OAuthToken` with the supplied values.
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

    /// Subject identifier reported by the identity issuer.
    public var sub: String?
    /// Email address associated with the identity.
    public var email: String?
    /// Whether the issuer reports the email as verified.
    public var emailVerified: Bool?
    /// Wallet address associated with the identity.
    public var walletAddress: String?
    /// Workspace identifier used to scope the request.
    public var workspaceId: String?
    /// ISO-8601 creation timestamp string (the backend returns a string here,
    /// not an epoch number).
    public var createdAt: String?
    /// Sourced verified-email domain matches; these do not prove employment.
    public var companyAffiliations: [CompanyAffiliation]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sub, email
        case emailVerified = "email_verified"
        case walletAddress = "wallet_address"
        case workspaceId = "workspace_id"
        case createdAt = "created_at"
        case companyAffiliations = "company_affiliations"
    }

    /// Creates a `UserInfo` with the supplied values.
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
    /// Decoded values from the response data field.
    public var data: UserInfo
    /// Creates a `UserInfoResponse` with the supplied values.
    public init(data: UserInfo) { self.data = data }
}
