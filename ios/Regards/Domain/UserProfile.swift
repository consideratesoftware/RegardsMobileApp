import Foundation

/// StoreKit-reflected entitlement tier (ARCHITECTURE.md §7, §4 revenue model).
public enum EntitlementTier: String, Codable, Sendable, CaseIterable {
    case free
    case trial
    case lifetime
}

/// Single-row app-level state (ARCHITECTURE.md §7).
public struct UserProfile: Sendable, Codable, Equatable, Hashable {
    public var onboardingCompletedAt: Date?
    public var entitlementTier: EntitlementTier
    public var entitlementRefreshedAt: Date
    public var trialStartedAt: Date?

    public init(
        onboardingCompletedAt: Date? = nil,
        entitlementTier: EntitlementTier = .free,
        entitlementRefreshedAt: Date = Date(),
        trialStartedAt: Date? = nil
    ) {
        self.onboardingCompletedAt = onboardingCompletedAt
        self.entitlementTier = entitlementTier
        self.entitlementRefreshedAt = entitlementRefreshedAt
        self.trialStartedAt = trialStartedAt
    }
}
