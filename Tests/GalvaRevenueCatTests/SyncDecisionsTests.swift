//
//  SyncDecisionsTests.swift
//  GalvaRevenueCatTests
//
//  Pins every sync rule on the plain `SyncState` logic: identity transitions,
//  trait dedupe, and when Galva is asked to reconcile transactions.
//

import Foundation
@testable import GalvaRevenueCat
import XCTest

final class SyncDecisionsTests: XCTestCase {

    private let uuidID = "B1FE821D-5597-4ABC-87B6-1F9647CFFD6E"

    /// Feed `updates` through a fresh state; return the actions of the kinds
    /// the test cares about.
    private func actions(
        followsRevenueCatIdentity: Bool = true,
        _ updates: [RevenueCatCustomer],
        keep: (SyncAction) -> Bool
    ) -> [SyncAction] {
        var state = SyncState(followsRevenueCatIdentity: followsRevenueCatIdentity)
        return updates.flatMap { state.apply($0) }.filter(keep)
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
             [.identify(userId: "user_42", appAccountToken: nil)]),

            ("UUID app user ID → also the appAccountToken",
             [.identified(uuidID)],
             [.identify(userId: uuidID, appAccountToken: UUID(uuidString: uuidID))]),

            ("same user again → identify once",
             [.identified("user_42"), .identified("user_42", entitlements: ["pro"])],
             [.identify(userId: "user_42", appAccountToken: nil)]),

            ("switch users → log out before identifying",
             [.identified("user_a"), .identified("user_b")],
             [.identify(userId: "user_a", appAccountToken: nil), .logOut,
              .identify(userId: "user_b", appAccountToken: nil)]),

            ("identified → anonymous → log out",
             [.identified("user_42"), .anonymous()],
             [.identify(userId: "user_42", appAccountToken: nil), .logOut]),

            ("anonymous throughout → never touch Galva identity",
             [.anonymous("$RCAnonymousID:1"), .anonymous("$RCAnonymousID:2")],
             []),

            ("log in again after logging out",
             [.identified("user_42"), .anonymous(), .identified("user_42")],
             [.identify(userId: "user_42", appAccountToken: nil), .logOut,
              .identify(userId: "user_42", appAccountToken: nil)]),
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

        XCTAssertEqual(state.apply(.identified("user_42", entitlements: ["pro"])), [
            .identify(userId: "user_42", appAccountToken: nil),
            .setTraits(RevenueCatTraits(.identified("user_42", entitlements: ["pro"]))),
        ])
        XCTAssertEqual(state.apply(.anonymous("$RCAnonymousID:9")), [
            .logOut,
            .setTraits(RevenueCatTraits(.anonymous("$RCAnonymousID:9"))),
        ])
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
