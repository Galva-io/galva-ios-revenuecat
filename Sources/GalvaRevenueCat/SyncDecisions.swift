//
//  SyncDecisions.swift
//  GalvaRevenueCat
//
//  What to do in Galva when RevenueCat's customer state changes, as plain
//  logic with no side effects. `CustomerSync` feeds it RevenueCat's user when
//  it connects, then each RevenueCat update, and carries out the actions it
//  returns, in order.
//
//  Identity (when following RevenueCat)
//  ─────────────────────────────────────
//  When the sync connects, Galva may already be identified: the previous
//  launch can end before the sync sees a `logIn` or `logOut`, and RevenueCat
//  can start as another user (`configure(withAPIKey:appUserID:)`). So it
//  compares RevenueCat's current user, known as soon as RevenueCat is
//  configured (even offline, with no `CustomerInfo` to emit), with Galva's
//  current user, and with the user the sync last mirrored, which
//  `CustomerSync` persists across launches:
//  • Identified as X, Galva already X → nothing. Unless X is a UUID that
//    isn't Galva's `appAccountToken` yet (the app identified Galva as X
//    without it) → identify(X) again, with the token.
//  • Identified as X, Galva identified as someone else
//      → logOut, then identify(X), so X never inherits their anonymous id or
//        `appAccountToken` override.
//  • Identified as X, Galva anonymous → identify(X).
//  • Anonymous, Galva still the user the sync last mirrored → logOut. It's
//    a `Purchases.logOut` the sync missed: RevenueCat resets its user
//    locally, but emits only once its follow-up fetch succeeds, so offline
//    (or killed first) the sync never saw it.
//  • Anonymous otherwise → nothing. The app may run Galva identity itself
//    while RevenueCat stays anonymous, and a Galva user the sync didn't
//    mirror is the app's to keep.
//  Updates compare with what the sync mirrored, not with Galva's user, which
//  lags: Galva applies identify and logOut asynchronously.
//  • Switched straight from X to Y (`logIn` without `logOut`)
//      → logOut, then identify(Y), for the same reason.
//  • Identified → anonymous → logOut.
//  • Identified as X, Galva last mirrored nobody → identify(X), after a
//    logOut if Galva is identified as someone else: a user the app
//    identified while RevenueCat was anonymous, as when connecting. Right
//    after the sync's own logOut, Galva can still read the old user; the
//    extra logOut that causes is harmless.
//  • Anonymous the whole time → nothing; the app may identify Galva itself.
//  With `.manual` the sync makes none of these calls and mirrors nobody.
//  A UUID app user ID is also passed as the `appAccountToken`: RevenueCat
//  attaches exactly that UUID to the purchases it makes, so purchases from
//  both SDKs resolve to the same Galva account.
//
//  Traits
//  ──────
//  `$gv_rc_appUserId`, `$gv_rc_originalAppUserId` and
//  `$gv_rc_activeEntitlements`, sent when they change, and again with the
//  next RevenueCat update after the Galva user changes, since traits belong
//  to the Galva user. Nothing observes Galva's user, so that includes
//  changes the sync didn't make (`.manual`, or the app identifying Galva
//  while RevenueCat is anonymous): the dedupe keys on Galva's user as each
//  update arrives. After the sync's own identify or logOut, Galva's user
//  reads as changed on the next update too, so the traits go out once more.
//
//  Reconciliation
//  ──────────────
//  RevenueCat emits whenever its customer info changes, not only its
//  purchases (an entitlement expiring, another user), so Galva is asked to
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

/// Galva's user, as `AppUser` reports it.
struct GalvaIdentity: Equatable, Sendable {
    /// `AppUser.identifiedUserId`; `nil` while Galva is anonymous.
    var userId: String?
    /// `AppUser.appAccountToken`. Changes on every logOut, even between two
    /// anonymous users.
    var appAccountToken: UUID?
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
    /// RevenueCat is anonymous or identity is managed by the app. Starts as
    /// what the previous launch left; `CustomerSync` persists every change.
    private(set) var mirroredUserID: String?
    /// Traits last sent, and the Galva user they were sent to.
    private(set) var sentTraits: RevenueCatTraits?
    private(set) var sentTraitsTo: GalvaIdentity?
    /// Purchases at the previous update; `nil` before the first one.
    private(set) var purchaseDates: [String: Date]?

    init(followsRevenueCatIdentity: Bool, lastMirroredUserID: String? = nil) {
        self.followsRevenueCatIdentity = followsRevenueCatIdentity
        self.mirroredUserID = lastMirroredUserID
    }

    /// The Galva calls to make when the sync connects to RevenueCat, before
    /// its first update. `galva` is Galva's user as it connects.
    mutating func connect(to revenueCat: RevenueCatUser, galva: GalvaIdentity) -> [SyncAction] {
        guard followsRevenueCatIdentity else {
            mirroredUserID = nil
            return []
        }
        let actions = identityActionsAtConnect(for: revenueCat, galva: galva)
        mirror(revenueCat)
        return actions
    }

    /// Fold one RevenueCat update into the state and return the Galva calls
    /// it calls for, in the order to make them. `galva` is Galva's user as
    /// the update arrives.
    mutating func apply(_ customer: RevenueCatCustomer, galva: GalvaIdentity) -> [SyncAction] {
        var actions: [SyncAction] = []
        if followsRevenueCatIdentity {
            actions = identityActions(for: customer.user, galvaUserID: galva.userId)
            mirror(customer.user)
        } else {
            mirroredUserID = nil
        }

        let traits = RevenueCatTraits(customer)
        if traits != sentTraits || galva != sentTraitsTo || !actions.isEmpty {
            actions.append(.setTraits(traits))
            sentTraits = traits
            sentTraitsTo = galva
        }

        if let previous = purchaseDates, previous != customer.purchaseDates {
            actions.append(.reconcileTransactions)
        }
        purchaseDates = customer.purchaseDates

        return actions
    }

    // MARK: - Private

    private mutating func mirror(_ revenueCat: RevenueCatUser) {
        mirroredUserID = revenueCat.isAnonymous ? nil : revenueCat.appUserID
    }

    private func identityActionsAtConnect(
        for revenueCat: RevenueCatUser,
        galva: GalvaIdentity
    ) -> [SyncAction] {
        if revenueCat.isAnonymous {
            // Only log out a user the sync put there; anyone else is the app's.
            guard let galvaUserID = galva.userId, galvaUserID == mirroredUserID else { return [] }
            return [.logOut]
        }
        guard let galvaUserID = galva.userId else { return [identify(revenueCat)] }
        guard galvaUserID == revenueCat.appUserID else { return [.logOut, identify(revenueCat)] }
        // Already X, but maybe identified without X's token.
        let token = UUID(uuidString: revenueCat.appUserID)
        return token == nil || token == galva.appAccountToken ? [] : [identify(revenueCat)]
    }

    private func identityActions(for revenueCat: RevenueCatUser, galvaUserID: String?) -> [SyncAction] {
        if revenueCat.isAnonymous {
            return mirroredUserID == nil ? [] : [.logOut]
        }
        guard revenueCat.appUserID != mirroredUserID else { return [] }
        // Galva's user: the one the sync mirrored or, when it mirrored
        // nobody, one the app identified.
        let current = mirroredUserID ?? galvaUserID
        return (current == nil || current == revenueCat.appUserID ? [] : [.logOut]) + [identify(revenueCat)]
    }

    private func identify(_ revenueCat: RevenueCatUser) -> SyncAction {
        .identify(userId: revenueCat.appUserID, appAccountToken: UUID(uuidString: revenueCat.appUserID))
    }
}
