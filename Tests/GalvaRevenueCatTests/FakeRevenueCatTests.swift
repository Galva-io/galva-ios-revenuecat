//
//  FakeRevenueCatTests.swift
//  GalvaRevenueCatTests
//
//  Pins `FakeRevenueCat` to what RevenueCat does, since the sync tests rely
//  on it: `CustomerInfoManager.sendUpdateIfChanged` sends customer info only
//  when its data differs from the last one sent, whoever the app user is;
//  `logIn` with a new ID while anonymous merges into the same customer; and
//  `logOut` switches to a new anonymous user with nothing cached.
//

import Foundation
@testable import GalvaRevenueCat
import XCTest

final class FakeRevenueCatTests: XCTestCase {

    func test_sendsOnlyWhenTheCustomersDataChanges() {
        let revenueCat = FakeRevenueCat()
        let anonymous = RevenueCatCustomer.anonymous()
        revenueCat.start(as: anonymous.user)

        revenueCat.fetched(anonymous)
        revenueCat.fetched(anonymous)
        revenueCat.signUp(as: "user_42")
        revenueCat.logIn(.identified("user_b"))
        revenueCat.logOut(to: "$RCAnonymousID:2")

        XCTAssertEqual(revenueCat.sent.map(\.appUserID), [anonymous.appUserID, "user_b"])
    }

    func test_signUp_keepsTheCustomer_underTheNewAppUserID() {
        let revenueCat = FakeRevenueCat()
        let anonymous = RevenueCatCustomer.anonymous()
        revenueCat.start(as: anonymous)

        revenueCat.signUp(as: "user_42")

        let snapshot = revenueCat.snapshot()
        XCTAssertEqual(snapshot.user, RevenueCatUser(appUserID: "user_42", isAnonymous: false))
        XCTAssertEqual(snapshot.customer?.originalAppUserID, anonymous.appUserID)
    }

    func test_logOut_cachesNothingForTheNewAnonymousUser() {
        let revenueCat = FakeRevenueCat()
        revenueCat.start(as: .identified("user_a"))

        revenueCat.logOut(to: "$RCAnonymousID:2")

        XCTAssertEqual(revenueCat.currentAppUserID, "$RCAnonymousID:2")
        XCTAssertNil(revenueCat.snapshot().customer)
    }

    func test_setDelegate_countsTheCacheAsSent_withoutSendingIt() {
        let revenueCat = FakeRevenueCat()
        let customer = RevenueCatCustomer.identified("user_a")
        revenueCat.start(as: customer)

        revenueCat.setDelegate()
        revenueCat.fetched(customer)

        XCTAssertEqual(revenueCat.sent.count, 0)
    }

    func test_customerUpdates_startWithTheLastOneSent() async {
        let revenueCat = FakeRevenueCat()
        revenueCat.logIn(.identified("user_a"))

        for await first in revenueCat.customerUpdates() {
            XCTAssertEqual(first.appUserID, "user_a")
            break
        }
    }
}
