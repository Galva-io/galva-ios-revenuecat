//
//  SyncDecisions.swift
//  GalvaRevenueCat
//
//  What to do in Galva when RevenueCat's customer state changes, as plain
//  logic with no side effects. `CustomerSync` feeds it each RevenueCat update
//  and carries out the actions it returns, in order.
//
//  Identity (when following RevenueCat)
//  ─────────────────────────────────────
//  • Identified as X, Galva last mirrored nobody → identify(X).
//  • Switched straight from X to Y (`logIn` without `logOut`)
//      → logOut, then identify(Y), so Y never inherits X's anonymous id or
//        `appAccountToken` override.
//  • Identified → anonymous → logOut.
//  • Anonymous the whole time → nothing; the app may identify Galva itself.
//  A UUID app user ID is also passed as the `appAccountToken`: RevenueCat
//  attaches exactly that UUID to the purchases it makes, so purchases from
//  both SDKs resolve to the same Galva account.
//
//  Traits
//  ──────
//  `$gv_rc_appUserId`, `$gv_rc_originalAppUserId` and
//  `$gv_rc_activeEntitlements`, sent when they change — and again after every
//  identity change, since traits belong to the Galva user.
//
//  Reconciliation
//  ──────────────
//  RevenueCat emits on every customer-info refresh, not only on real changes
//  (its equality includes the response's request date), so Galva is asked to
//  reconcile transactions only when purchases change: a new purchase or
//  renewal, typically from the app's own RevenueCat paywall. Never on the
//  first update — Galva's own launch sweep covers that.
//

import Foundation

/// A Galva call to make.
enum SyncAction: Equatable, Sendable {
    case identify(userId: String, appAccountToken: UUID?)
    case logOut
    case setTraits(RevenueCatTraits)
    case reconcileTransactions
}

/// The RevenueCat state Galva keeps as user traits.
struct RevenueCatTraits: Equatable, Sendable {
    static let appUserIDKey = "$gv_rc_appUserId"
    static let originalAppUserIDKey = "$gv_rc_originalAppUserId"
    static let activeEntitlementsKey = "$gv_rc_activeEntitlements"

    var appUserID: String
    var originalAppUserID: String
    var activeEntitlements: [String]

    init(_ customer: RevenueCatCustomer) {
        appUserID = customer.appUserID
        originalAppUserID = customer.originalAppUserID
        activeEntitlements = customer.activeEntitlements
    }

    /// The traits as passed to `AppUser.set(_:)`.
    var galvaTraits: [String: Any] {
        [
            Self.appUserIDKey: appUserID,
            Self.originalAppUserIDKey: originalAppUserID,
            Self.activeEntitlementsKey: activeEntitlements,
        ]
    }
}

/// What the sync remembers between RevenueCat updates.
struct SyncState: Equatable, Sendable {

    let followsRevenueCatIdentity: Bool

    /// RevenueCat app user ID last mirrored into Galva; `nil` while
    /// RevenueCat is anonymous or identity is managed by the app.
    private(set) var mirroredUserID: String?
    /// Traits last sent for the current Galva user.
    private(set) var sentTraits: RevenueCatTraits?
    /// Purchases at the previous update; `nil` before the first one.
    private(set) var purchaseDates: [String: Date]?

    init(followsRevenueCatIdentity: Bool) {
        self.followsRevenueCatIdentity = followsRevenueCatIdentity
    }

    /// Fold one RevenueCat update into the state and return the Galva calls
    /// it calls for, in the order to make them.
    mutating func apply(_ customer: RevenueCatCustomer) -> [SyncAction] {
        var actions = followsRevenueCatIdentity ? identityActions(for: customer) : []

        let traits = RevenueCatTraits(customer)
        if traits != sentTraits {
            actions.append(.setTraits(traits))
            sentTraits = traits
        }

        if let previous = purchaseDates, previous != customer.purchaseDates {
            actions.append(.reconcileTransactions)
        }
        purchaseDates = customer.purchaseDates

        return actions
    }

    private mutating func identityActions(for customer: RevenueCatCustomer) -> [SyncAction] {
        if customer.isAnonymous {
            guard mirroredUserID != nil else { return [] }
            mirroredUserID = nil
            sentTraits = nil
            return [.logOut]
        }
        guard customer.appUserID != mirroredUserID else { return [] }

        var actions: [SyncAction] = mirroredUserID == nil ? [] : [.logOut]
        actions.append(.identify(
            userId: customer.appUserID,
            appAccountToken: UUID(uuidString: customer.appUserID)
        ))
        mirroredUserID = customer.appUserID
        sentTraits = nil
        return actions
    }
}
