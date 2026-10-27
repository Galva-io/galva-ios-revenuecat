//
//  SyncDecisions.swift
//  GalvaRevenueCat
//
//  What to do in Galva when RevenueCat's state changes, as plain logic with
//  no side effects. `CustomerSync` feeds it RevenueCat's state when it
//  connects, then each RevenueCat update and each fresh read of RevenueCat,
//  and carries out the actions it returns, in order.
//
//  Fresh reads (`refresh`) are there because RevenueCat's updates follow
//  the customer, not the app user ID: RevenueCat sends one only when the
//  customer's data changes. A `logIn` that merges an anonymous user into a
//  new ID, the usual sign-up, keeps the same customer and sends nothing, and
//  a `logOut` sends nothing until RevenueCat has fetched its new anonymous
//  user. A fresh read is RevenueCat's user with the customer info it has
//  cached for them, if any, and is decided like an update.
//
//  Identity (when following RevenueCat)
//  ─────────────────────────────────────
//  When the sync connects, Galva may already be identified: the previous
//  launch can end before the sync sees a `logIn` or `logOut`, and RevenueCat
//  can start as another user (`configure(withAPIKey:appUserID:)`). So it
//  compares RevenueCat's current user, known as soon as RevenueCat is
//  configured (even offline, with no `CustomerInfo` cached), with Galva's
//  current user, and with the user the sync last mirrored, which
//  `CustomerSync` persists across launches:
//  • Identified as X, Galva already X → nothing.
//  • Identified as X, Galva identified as someone else
//      → logOut, then identify(X), so X never inherits their anonymous id or
//        `appAccountToken` override.
//  • Identified as X, Galva anonymous → identify(X).
//  • Anonymous, Galva still the user the sync last mirrored → logOut. It's
//    a `Purchases.logOut` the sync missed: the app quit before the sync
//    noticed it.
//  • Anonymous otherwise → nothing. The app may run Galva identity itself
//    while RevenueCat stays anonymous, and a Galva user the sync didn't
//    mirror is the app's to keep.
//  Updates and fresh reads compare with what the sync mirrored, not with
//  Galva's user, which lags: Galva applies identify and logOut
//  asynchronously.
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
//
//  The sync never sets Galva's `appAccountToken`. RevenueCat doesn't expose
//  the token it attaches to the purchases it makes, if any (today it sends
//  the app user ID only when that parses as a UUID), so deriving one from
//  the app user ID would guess at RevenueCat's internals and replace the
//  token Galva attaches to its own purchases. Galva matches every purchase,
//  RevenueCat's included, to its subscriber by transaction ID instead
//  (`Galva.reconcileTransactions()`).
//
//  Traits
//  ──────
//  `$gv_rc_appUserId`, `$gv_rc_originalAppUserId` and
//  `$gv_rc_activeEntitlements`, sent when the sync connects with customer
//  info cached, then when they change, and again with the next update or
//  fresh read after the Galva user changes, since traits belong to the
//  Galva user. Nothing observes Galva's user, so that includes changes the
//  sync didn't make (`.manual`, or the app identifying Galva while
//  RevenueCat is anonymous): the dedupe keys on Galva's user as each update
//  or read arrives. After the sync's own identify or logOut, Galva's user
//  reads as changed the next time too, so the traits go out once more.
//
//  Reconciliation
//  ──────────────
//  RevenueCat's customer info changes for more than its purchases (an
//  entitlement expiring, another user), so Galva is asked to reconcile
//  transactions only when purchases change: a new purchase or renewal,
//  typically from the app's own RevenueCat paywall. Never for the first
//  customer state the sync sees (the cache when it connects, else the first
//  update): Galva's own launch sweep covers what RevenueCat knew at launch.
//

import Foundation

/// A Galva call to make.
enum SyncAction: Equatable, Sendable {
    case identify(userId: String)
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
struct SyncState: Sendable {

    let followsRevenueCatIdentity: Bool

    /// RevenueCat app user ID last mirrored into Galva; `nil` while
    /// RevenueCat is anonymous or identity is managed by the app. Starts as
    /// what the previous launch left; `CustomerSync` persists every change.
    private(set) var mirroredUserID: String?
    /// RevenueCat's app user ID as the sync last saw it, anonymous or not;
    /// `nil` before it connects. When RevenueCat's differs, it's time for a
    /// fresh read.
    private(set) var seenAppUserID: String?
    /// Traits last sent, and the Galva user they were sent to.
    private(set) var sentTraits: RevenueCatTraits?
    private(set) var sentTraitsTo: GalvaIdentity?
    /// Purchases in the last customer state; `nil` before the first one.
    private(set) var purchaseDates: [String: Date]?

    init(followsRevenueCatIdentity: Bool, lastMirroredUserID: String? = nil) {
        self.followsRevenueCatIdentity = followsRevenueCatIdentity
        self.mirroredUserID = lastMirroredUserID
    }

    /// The Galva calls to make when the sync connects to RevenueCat, before
    /// its first update. `galva` is Galva's user as it connects.
    mutating func connect(to revenueCat: RevenueCatSnapshot, galva: GalvaIdentity) -> [SyncAction] {
        seenAppUserID = revenueCat.user.appUserID
        var actions: [SyncAction] = []
        if followsRevenueCatIdentity {
            actions = identityActionsAtConnect(for: revenueCat.user, galva: galva)
            mirror(revenueCat.user)
        } else {
            mirroredUserID = nil
        }
        guard let customer = revenueCat.customer else { return actions }
        return actions + customerActions(for: customer, galva: galva, identityChanged: !actions.isEmpty)
    }

    /// Fold one RevenueCat update into the state and return the Galva calls
    /// it calls for, in the order to make them. `galva` is Galva's user as
    /// the update arrives.
    mutating func apply(_ customer: RevenueCatCustomer, galva: GalvaIdentity) -> [SyncAction] {
        let actions = follow(customer.user, galva: galva)
        return actions + customerActions(for: customer, galva: galva, identityChanged: !actions.isEmpty)
    }

    /// Fold a fresh read of RevenueCat into the state, like an update. With
    /// no customer info cached for RevenueCat's user yet, only identity is
    /// decided; traits and purchases wait for the update RevenueCat sends
    /// once it has fetched it.
    mutating func refresh(_ revenueCat: RevenueCatSnapshot, galva: GalvaIdentity) -> [SyncAction] {
        guard let customer = revenueCat.customer else {
            return follow(revenueCat.user, galva: galva)
        }
        return apply(customer, galva: galva)
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
        return galvaUserID == revenueCat.appUserID ? [] : [.logOut, identify(revenueCat)]
    }

    /// The identity calls for RevenueCat's user once connected, mirroring
    /// it when following RevenueCat.
    private mutating func follow(_ revenueCat: RevenueCatUser, galva: GalvaIdentity) -> [SyncAction] {
        seenAppUserID = revenueCat.appUserID
        guard followsRevenueCatIdentity else {
            mirroredUserID = nil
            return []
        }
        let actions = identityActions(for: revenueCat, galvaUserID: galva.userId)
        mirror(revenueCat)
        return actions
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
        .identify(userId: revenueCat.appUserID)
    }

    /// The traits, when they or Galva's user changed since they were last
    /// sent, then a reconcile when purchases changed since the last customer
    /// state.
    private mutating func customerActions(
        for customer: RevenueCatCustomer,
        galva: GalvaIdentity,
        identityChanged: Bool
    ) -> [SyncAction] {
        var actions: [SyncAction] = []
        let traits = RevenueCatTraits(customer)
        if traits != sentTraits || galva != sentTraitsTo || identityChanged {
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
}
