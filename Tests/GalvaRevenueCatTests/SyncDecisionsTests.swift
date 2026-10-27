//
//  SyncDecisionsTests.swift
//  GalvaRevenueCatTests
//
//  Pins every sync rule on the plain `SyncState` logic: identity transitions
//  when the sync connects and after it, trait dedupe, and when Galva is
//  asked to reconcile transactions.
//

import Foundation
@testable import GalvaRevenueCat
import XCTest

final class SyncDecisionsTests: XCTestCase {

    private let uuidID = "B1FE821D-5597-4ABC-87B6-1F9647CFFD6E"

    /// Galva with nobody identified, as on a fresh install.
    private static let anonymousGalva = GalvaIdentity(userId: nil, appAccountToken: UUID())

    private static func galva(_ userId: String) -> GalvaIdentity {
        GalvaIdentity(userId: userId, appAccountToken: UUID())
    }

    /// RevenueCat as `customer`'s user, with nothing cached for them.
    private static func uncached(_ customer: RevenueCatCustomer) -> RevenueCatSnapshot {
        RevenueCatSnapshot(uncached: customer.user)
    }

    /// Connect a fresh state as the first update's user, then feed it
    /// `updates`, as `CustomerSync` does, with Galva reporting `galva`
    /// throughout; return the actions of the kinds the test cares about.
    private func actions(
        followsRevenueCatIdentity: Bool = true,
        lastMirroredUserID: String? = nil,
        galva: GalvaIdentity = anonymousGalva,
        _ updates: [RevenueCatCustomer],
        keep: (SyncAction) -> Bool
    ) -> [SyncAction] {
        var state = SyncState(
            followsRevenueCatIdentity: followsRevenueCatIdentity,
            lastMirroredUserID: lastMirroredUserID
        )
        let atConnect = updates.first.map { state.connect(to: Self.uncached($0), galva: galva) } ?? []
        return (atConnect + updates.flatMap { state.apply($0, galva: galva) }).filter(keep)
    }

    private func isIdentity(_ action: SyncAction) -> Bool {
        switch action {
        case .identify, .logOut: true
        default: false
        }
    }

    // MARK: - Identity

    func test_identityTransitions() {
        let cases: [(String, [RevenueCatCustomer], [SyncAction])] = [
            ("identified → identify",
             [.identified("user_42")],
             [.identify(userId: "user_42")]),

            ("UUID app user ID → identified like any other, with no appAccountToken",
             [.identified(uuidID)],
             [.identify(userId: uuidID)]),

            ("same user again → identify once",
             [.identified("user_42"), .identified("user_42", entitlements: ["pro"])],
             [.identify(userId: "user_42")]),

            ("switch users → log out before identifying",
             [.identified("user_a"), .identified("user_b")],
             [.identify(userId: "user_a"), .logOut,
              .identify(userId: "user_b")]),

            ("identified → anonymous → log out",
             [.identified("user_42"), .anonymous()],
             [.identify(userId: "user_42"), .logOut]),

            ("anonymous throughout → never touch Galva identity",
             [.anonymous("$RCAnonymousID:1"), .anonymous("$RCAnonymousID:2")],
             []),

            ("log in again after logging out",
             [.identified("user_42"), .anonymous(), .identified("user_42")],
             [.identify(userId: "user_42"), .logOut,
              .identify(userId: "user_42")]),
        ]
        for (name, updates, expected) in cases {
            XCTAssertEqual(actions(updates, keep: isIdentity), expected, name)
        }
    }

    func test_manualIdentity_leavesGalvaIdentityAlone() {
        let result = actions(
            followsRevenueCatIdentity: false,
            [.identified("user_a"), .identified("user_b"), .anonymous()],
            keep: isIdentity
        )

        XCTAssertEqual(result, [])
    }

    // MARK: - Identity when connecting

    func test_launch_revenueCatIdentified_matchesGalvasCurrentUser() {
        let cases: [(String, GalvaIdentity, [SyncAction])] = [
            ("Galva already X → no identity calls",
             Self.galva("user_b"),
             []),

            // E.g. RevenueCat configured with `appUserID:` after a switch, or
            // the app killed before the sync saw the switch.
            ("Galva identified as someone else → log out, then identify X",
             Self.galva("user_a"),
             [.logOut, .identify(userId: "user_b")]),

            ("Galva anonymous → identify X",
             Self.anonymousGalva,
             [.identify(userId: "user_b")]),
        ]
        for (name, galva, expected) in cases {
            for lastMirrored in [nil, "user_a", "user_b"] {
                XCTAssertEqual(
                    actions(lastMirroredUserID: lastMirrored, galva: galva, [.identified("user_b")], keep: isIdentity),
                    expected,
                    "\(name), last mirrored \(lastMirrored ?? "nobody")"
                )
            }
        }
    }

    func test_launch_revenueCatAnonymous_logsOutOnlyTheUserTheSyncMirrored() {
        let cases: [(String, String?, GalvaIdentity, [SyncAction])] = [
            // RevenueCat logged out, but the sync never saw it: offline, its
            // follow-up fetch failed and the stream didn't emit, or the app
            // was killed first.
            ("Galva is still the user the sync last mirrored → log out",
             "user_a", Self.galva("user_a"), [.logOut]),

            ("Galva identified by the app itself → nothing",
             nil, Self.galva("app_user"), []),

            ("Galva identified by the app, not the user the sync mirrored → nothing",
             "user_a", Self.galva("app_user"), []),

            ("Galva already anonymous → nothing",
             "user_a", Self.anonymousGalva, []),

            ("nobody mirrored, Galva anonymous → nothing",
             nil, Self.anonymousGalva, []),
        ]
        for (name, lastMirrored, galva, expected) in cases {
            XCTAssertEqual(
                actions(lastMirroredUserID: lastMirrored, galva: galva, [.anonymous()], keep: isIdentity),
                expected,
                name
            )
        }
    }

    func test_launch_missedLogOut_thenLogIn_newUserDoesNotInherit() {
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")

        XCTAssertEqual(state.connect(to: Self.uncached(.anonymous()), galva: Self.galva("user_a")), [.logOut])
        XCTAssertEqual(state.apply(.anonymous(), galva: Self.anonymousGalva).filter(isIdentity), [])
        XCTAssertEqual(state.apply(.identified("user_b"), galva: Self.anonymousGalva).filter(isIdentity), [
            .identify(userId: "user_b"),
        ])
    }

    func test_connect_nothingCached_makesOnlyIdentityCalls_theFirstUpdateSendsTraits() {
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")
        let customer = RevenueCatCustomer.identified("user_b", purchases: ["pro.month": Date(timeIntervalSince1970: 1_800_000_000)])

        XCTAssertEqual(state.connect(to: Self.uncached(customer), galva: Self.galva("user_a")), [
            .logOut, .identify(userId: "user_b"),
        ])
        XCTAssertEqual(
            state.apply(customer, galva: Self.galva("user_b")),
            [.setTraits(RevenueCatTraits(customer))],
            "no identity calls again, and no reconcile on the first update"
        )
    }

    func test_connect_cached_sendsTraits_andRevenueCatsFirstUpdateCanReconcile() {
        // RevenueCat's first update may be the app's own paywall purchase:
        // when the cache matches what RevenueCat fetches at launch, or a
        // `PurchasesDelegate` set later counted it as sent, nothing comes
        // before it.
        var state = SyncState(followsRevenueCatIdentity: true)
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let cached = RevenueCatCustomer.identified("user_a", purchases: ["pro.month": day1])
        let bought = RevenueCatCustomer.identified("user_a", purchases: [
            "pro.month": day1,
            "pro.year": day1.addingTimeInterval(60),
        ])

        XCTAssertEqual(state.connect(to: RevenueCatSnapshot(cached), galva: Self.anonymousGalva), [
            .identify(userId: "user_a"),
            .setTraits(RevenueCatTraits(cached)),
        ], "no reconcile: Galva's launch sweep covers what RevenueCat knew at launch")
        XCTAssertEqual(state.apply(bought, galva: Self.galva("user_a")).filter(isReconcile), [.reconcileTransactions])
    }

    func test_launch_galvaAlreadyX_makesNoCalls_evenForAUUIDAppUserID() {
        // E.g. the app called `AppUser.identify(userId: Purchases.shared.appUserID)`
        // before adopting the integration. RevenueCat doesn't expose the
        // token it attaches to its purchases, so a UUID app user ID is no
        // reason to set Galva's.
        let cases: [(String, String, GalvaIdentity, [SyncAction])] = [
            ("UUID app user ID, Galva's own token → nothing",
             uuidID, GalvaIdentity(userId: uuidID, appAccountToken: UUID()),
             []),

            ("other app user ID → nothing",
             "user_b", Self.galva("user_b"),
             []),
        ]
        for (name, appUserID, galva, expected) in cases {
            XCTAssertEqual(
                actions(lastMirroredUserID: appUserID, galva: galva, [.identified(appUserID)], keep: isIdentity),
                expected,
                name
            )
        }
    }

    func test_afterLaunch_logIn_logsOutAGalvaUserTheAppIdentified() {
        // RevenueCat anonymous at launch while the app runs Galva identity
        // itself; later in the session, `Purchases.logIn` as someone else.
        // Same rule as when that state is seen at launch: rc_user never
        // inherits app_user's anonymous id or `appAccountToken` override.
        let appUser = Self.galva("app_user")
        let cases: [(String, GalvaIdentity, GalvaIdentity, [SyncAction])] = [
            ("app identified Galva before launch",
             appUser, appUser,
             [.logOut, .identify(userId: "rc_user")]),

            ("app identified Galva during the session",
             Self.anonymousGalva, appUser,
             [.logOut, .identify(userId: "rc_user")]),

            ("app identified Galva as the same user → just identify",
             Self.anonymousGalva, Self.galva("rc_user"),
             [.identify(userId: "rc_user")]),

            ("Galva anonymous throughout → just identify",
             Self.anonymousGalva, Self.anonymousGalva,
             [.identify(userId: "rc_user")]),
        ]
        for (name, atLaunch, atLogIn, expected) in cases {
            var state = SyncState(followsRevenueCatIdentity: true)
            XCTAssertEqual(state.connect(to: Self.uncached(.anonymous()), galva: atLaunch), [], name)
            XCTAssertEqual(state.apply(.anonymous(), galva: atLaunch).filter(isIdentity), [], name)

            XCTAssertEqual(state.apply(.identified("rc_user"), galva: atLogIn).filter(isIdentity), expected, name)
        }
    }

    func test_afterTheSyncsOwnLogOut_galvaStillReadingTheOldUser_addsALogOut() {
        // Galva applies logOut asynchronously, so the next login can still
        // read user_a. Logging out twice is harmless.
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")
        let stale = Self.galva("user_a")

        XCTAssertEqual(state.connect(to: Self.uncached(.identified("user_a")), galva: stale), [])
        XCTAssertEqual(state.apply(.anonymous(), galva: stale).filter(isIdentity), [.logOut])
        XCTAssertEqual(state.apply(.identified("user_b"), galva: stale).filter(isIdentity), [
            .logOut, .identify(userId: "user_b"),
        ])
    }

    func test_afterLaunch_followsWhatTheSyncMirrored_notGalvasLaggingIdentity() {
        // Galva applies identify/logOut asynchronously, so a later update can
        // still read the old user. Updates consult Galva's user only when the
        // sync mirrored nobody.
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")
        let stale = Self.galva("user_a")

        XCTAssertEqual(state.apply(.identified("user_b"), galva: stale).filter(isIdentity), [
            .logOut, .identify(userId: "user_b"),
        ])
        XCTAssertEqual(state.apply(.identified("user_b"), galva: stale).filter(isIdentity), [])
        XCTAssertEqual(state.apply(.anonymous(), galva: stale).filter(isIdentity), [.logOut])
    }

    func test_mirroredUserID_tracksRevenueCatsIdentifiedUser() {
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")
        XCTAssertEqual(state.mirroredUserID, "user_a", "starts from the previous launch")

        _ = state.connect(to: Self.uncached(.identified("user_b")), galva: Self.galva("user_b"))
        XCTAssertEqual(state.mirroredUserID, "user_b", "Galva already user_b: nothing to call, still mirrored")

        _ = state.apply(.identified("user_c"), galva: Self.galva("user_b"))
        XCTAssertEqual(state.mirroredUserID, "user_c")

        _ = state.apply(.anonymous(), galva: Self.galva("user_c"))
        XCTAssertNil(state.mirroredUserID)
    }

    func test_launch_anonymousCarveOut_forgetsTheLastMirroredUser() {
        var state = SyncState(followsRevenueCatIdentity: true, lastMirroredUserID: "user_a")

        XCTAssertEqual(state.connect(to: Self.uncached(.anonymous()), galva: Self.galva("app_user")), [])

        XCTAssertNil(state.mirroredUserID)
    }

    func test_manualIdentity_atLaunch_leavesGalvaAlone_andMirrorsNobody() {
        var state = SyncState(followsRevenueCatIdentity: false, lastMirroredUserID: "user_a")

        XCTAssertEqual(state.connect(to: Self.uncached(.anonymous()), galva: Self.galva("user_a")), [])
        XCTAssertNil(state.mirroredUserID)
        XCTAssertEqual(state.apply(.anonymous(), galva: Self.galva("user_a")).filter(isIdentity), [])
        XCTAssertEqual(state.apply(.identified("user_b"), galva: Self.galva("user_a")).filter(isIdentity), [])
        XCTAssertNil(state.mirroredUserID)
    }

    // MARK: - Fresh reads

    func test_refresh_afterASignUp_identifiesAndSendsTheMergedCustomersTraits() {
        // `logIn` merged the anonymous user into user_42: the same customer,
        // so RevenueCat sent no update, but its cache is under the new ID.
        var state = SyncState(followsRevenueCatIdentity: true)
        let anonymous = RevenueCatCustomer.anonymous()
        let merged = anonymous.withUser(RevenueCatUser(appUserID: "user_42", isAnonymous: false))
        XCTAssertEqual(state.connect(to: RevenueCatSnapshot(anonymous), galva: Self.anonymousGalva), [
            .setTraits(RevenueCatTraits(anonymous)),
        ])

        XCTAssertEqual(state.refresh(RevenueCatSnapshot(merged), galva: Self.anonymousGalva), [
            .identify(userId: "user_42"),
            .setTraits(RevenueCatTraits(merged)),
        ])
        XCTAssertEqual(state.mirroredUserID, "user_42")
    }

    func test_refresh_nothingCached_decidesIdentityOnly() {
        // A `logOut` offline: RevenueCat's new anonymous user has nothing
        // cached until RevenueCat fetches it, and sends it then.
        var state = SyncState(followsRevenueCatIdentity: true)
        _ = state.connect(to: RevenueCatSnapshot(.identified("user_a")), galva: Self.anonymousGalva)
        let anonymous = RevenueCatCustomer.anonymous("$RCAnonymousID:2")

        XCTAssertEqual(state.refresh(Self.uncached(anonymous), galva: Self.galva("user_a")), [.logOut])
        XCTAssertNil(state.mirroredUserID)
        XCTAssertEqual(state.apply(anonymous, galva: Self.anonymousGalva), [
            .setTraits(RevenueCatTraits(anonymous)),
        ])
    }

    func test_refresh_withNothingNew_makesNoCalls() {
        var state = SyncState(followsRevenueCatIdentity: true)
        let customer = RevenueCatCustomer.identified("user_a", entitlements: ["pro"])
        let galva = Self.galva("user_a")
        _ = state.connect(to: RevenueCatSnapshot(customer), galva: galva)

        XCTAssertEqual(state.refresh(RevenueCatSnapshot(customer), galva: galva), [])
        XCTAssertEqual(state.refresh(Self.uncached(customer), galva: galva), [])
    }

    func test_refresh_manual_resendsTraitsAfterTheAppSwitchesGalvaUsers() {
        var state = SyncState(followsRevenueCatIdentity: false)
        let customer = RevenueCatCustomer.identified("rc_1", entitlements: ["pro"])
        _ = state.connect(to: RevenueCatSnapshot(customer), galva: Self.galva("galva_1"))

        XCTAssertEqual(state.refresh(RevenueCatSnapshot(customer), galva: Self.galva("galva_2")), [
            .setTraits(RevenueCatTraits(customer)),
        ])
    }

    func test_seenAppUserID_isRevenueCatsLatest_fromEveryRead() {
        var state = SyncState(followsRevenueCatIdentity: false)
        XCTAssertNil(state.seenAppUserID)

        _ = state.connect(to: Self.uncached(.anonymous("$RCAnonymousID:1")), galva: Self.anonymousGalva)
        XCTAssertEqual(state.seenAppUserID, "$RCAnonymousID:1", "when connecting")
        _ = state.apply(.identified("user_a"), galva: Self.anonymousGalva)
        XCTAssertEqual(state.seenAppUserID, "user_a", "from an update")
        _ = state.refresh(Self.uncached(.identified("user_b")), galva: Self.anonymousGalva)
        XCTAssertEqual(state.seenAppUserID, "user_b", "from a fresh read, with .manual too")
    }

    // MARK: - Traits

    private func isTraits(_ action: SyncAction) -> Bool {
        if case .setTraits = action { true } else { false }
    }

    func test_traits_sentOnlyWhenTheyChange() {
        let result = actions(
            [.identified("user_42"), .identified("user_42"), .identified("user_42", entitlements: ["pro"])],
            keep: isTraits
        )

        XCTAssertEqual(result, [
            .setTraits(RevenueCatTraits(.identified("user_42"))),
            .setTraits(RevenueCatTraits(.identified("user_42", entitlements: ["pro"]))),
        ])
    }

    func test_traits_resentForEachNewGalvaUser() {
        var state = SyncState(followsRevenueCatIdentity: true)
        let galva = Self.anonymousGalva

        XCTAssertEqual(state.apply(.identified("user_42", entitlements: ["pro"]), galva: galva), [
            .identify(userId: "user_42"),
            .setTraits(RevenueCatTraits(.identified("user_42", entitlements: ["pro"]))),
        ])
        XCTAssertEqual(state.apply(.anonymous("$RCAnonymousID:9"), galva: galva), [
            .logOut,
            .setTraits(RevenueCatTraits(.anonymous("$RCAnonymousID:9"))),
        ])
    }

    func test_traits_resentAfterTheAppSwitchesGalvaUsers() {
        // `.manual`: RevenueCat stays the same while the app calls
        // `AppUser.logOut()` and `identify(…)` itself.
        var state = SyncState(followsRevenueCatIdentity: false)
        let customer = RevenueCatCustomer.identified("rc_1", entitlements: ["pro"])
        let traits = SyncAction.setTraits(RevenueCatTraits(customer))
        let first = Self.galva("galva_1")
        let loggedOut = Self.anonymousGalva
        let second = GalvaIdentity(userId: "galva_2", appAccountToken: loggedOut.appAccountToken)

        XCTAssertEqual(state.apply(customer, galva: first), [traits])
        XCTAssertEqual(state.apply(customer, galva: first), [], "same Galva user → not resent")
        XCTAssertEqual(state.apply(customer, galva: loggedOut), [traits], "logged out → the new anonymous user gets them")
        XCTAssertEqual(state.apply(customer, galva: second), [traits], "identified → the new user gets them")
        XCTAssertEqual(state.apply(customer, galva: second), [])
    }

    func test_traits_mapToGalvaKeys() {
        let traits = RevenueCatTraits(.identified("user_42", entitlements: ["plus", "pro"])).galvaTraits

        XCTAssertEqual(traits["$gv_rc_appUserId"] as? String, "user_42")
        XCTAssertEqual(traits["$gv_rc_originalAppUserId"] as? String, "user_42")
        XCTAssertEqual(traits["$gv_rc_activeEntitlements"] as? [String], ["plus", "pro"])
    }

    // MARK: - Reconciliation

    private func isReconcile(_ action: SyncAction) -> Bool {
        action == .reconcileTransactions
    }

    func test_reconcile_onlyWhenPurchasesChange() {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let cases: [(String, [RevenueCatCustomer], Int)] = [
            ("first update → no reconcile (Galva's launch sweep covers it)",
             [.identified("u", purchases: ["pro.month": day1])], 0),

            ("refresh with the same purchases → no reconcile",
             [.identified("u", purchases: ["pro.month": day1]),
              .identified("u", purchases: ["pro.month": day1])], 0),

            ("new purchase → reconcile",
             [.identified("u"), .identified("u", purchases: ["pro.month": day1])], 1),

            ("renewal (later purchase date) → reconcile",
             [.identified("u", purchases: ["pro.month": day1]),
              .identified("u", purchases: ["pro.month": day2])], 1),
        ]
        for (name, updates, expected) in cases {
            XCTAssertEqual(actions(updates, keep: isReconcile).count, expected, name)
        }
    }
}
