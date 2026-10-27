//
//  CustomerSyncTests.swift
//  GalvaRevenueCatTests
//
//  The `CustomerSync` actor: waits for RevenueCat to be configured, matches
//  Galva to RevenueCat's user and cached customer info as it connects,
//  applies updates in order, off the main thread, reads RevenueCat again
//  when the app becomes active and when its app user ID changes, carries
//  identity across launches, and logs through Galva's logger.
//
//  `FakeRevenueCat` sends updates the way RevenueCat does: only when the
//  customer's data changes.
//

import Foundation
import Galva
@testable import GalvaRevenueCat
import XCTest

final class CustomerSyncTests: XCTestCase {

    private var revenueCat: FakeRevenueCat!
    private var galva: FakeGalva!
    private var store: FakeMirroredUserStore!
    private var logger: RecordingLogger!
    private var app: FakeApp!

    override func setUp() {
        revenueCat = FakeRevenueCat()
        galva = FakeGalva()
        store = FakeMirroredUserStore()
        logger = RecordingLogger()
        app = FakeApp()
    }

    private func startSync(followsRevenueCatIdentity: Bool = true) -> Task<Void, Never> {
        let sync = CustomerSync(
            followsRevenueCatIdentity: followsRevenueCatIdentity,
            galva: galva,
            store: store,
            logger: logger
        )
        let revenueCat = revenueCat!
        let signals = app.signals
        return Task { await sync.run(revenueCat: revenueCat, app: signals) }
    }

    /// Start the sync and wait until it has connected and listens to
    /// RevenueCat's updates, so the updates a test sends reach it.
    private func startFollowing(followsRevenueCatIdentity: Bool = true) async -> Task<Void, Never> {
        let run = startSync(followsRevenueCatIdentity: followsRevenueCatIdentity)
        let listening = await eventually { self.revenueCat.observerCount == 1 }
        XCTAssertTrue(listening, "the sync never listened to RevenueCat's updates")
        return run
    }

    func test_waitsUntilRevenueCatIsConfigured_thenConnectsWhenTheAppBecomesActive() async {
        revenueCat.isConfigured = false
        revenueCat.start(as: .identified("user_42"))
        let run = startSync()
        defer { run.cancel() }

        app.becomeActive()
        app.tick()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(revenueCat.snapshotReads, 0, "must not touch RevenueCat before it's configured")
        XCTAssertEqual(revenueCat.customerUpdatesCalls, 0)
        XCTAssertEqual(galva.calls, [], "nor match Galva to its user")
        XCTAssertTrue(logger.messages.contains { $0.contains("isn't configured yet") })

        revenueCat.isConfigured = true
        app.becomeActive()

        let identified = await eventually {
            self.galva.calls.contains(.identify(userId: "user_42"))
        }
        XCTAssertTrue(identified)
        XCTAssertFalse(app.stopped, "keeps following the app once connected")
    }

    func test_connectsOnATick_onceRevenueCatIsConfigured() async {
        revenueCat.isConfigured = false
        revenueCat.start(as: .identified("user_42"))
        let run = startSync()
        defer { run.cancel() }

        revenueCat.isConfigured = true
        app.tick()

        let identified = await eventually {
            self.galva.calls.contains(.identify(userId: "user_42"))
        }
        XCTAssertTrue(identified)
    }

    func test_stopsFollowingTheAppWhenTheRunEnds() async {
        let run = await startFollowing()
        XCTAssertFalse(app.stopped)

        run.cancel()
        await run.value

        XCTAssertTrue(app.stopped)
    }

    func test_stopsWaitingWhenTheAppSignalsEnd() async {
        revenueCat.isConfigured = false
        let run = startSync()

        app.endWithoutStop()
        await run.value

        XCTAssertEqual(revenueCat.customerUpdatesCalls, 0)
    }

    func test_followsEachChangeInOrder_persistingTheMirroredUser_offTheMainThread() async {
        let run = await startFollowing()
        defer { run.cancel() }

        revenueCat.logIn(.identified("user_a"))
        let a = await eventually { self.store.saves == ["user_a"] }
        revenueCat.fetched(.identified("user_a", entitlements: ["pro"]))
        let pro = await waitForTraits(2)
        revenueCat.logIn(.identified("user_b"))
        let b = await eventually { self.store.saves == ["user_a", "user_b"] }
        revenueCat.logOut(to: "$RCAnonymousID:2")
        revenueCat.fetched(.anonymous("$RCAnonymousID:2"))
        let anonymous = await eventually { self.store.saves == ["user_a", "user_b", nil] }

        XCTAssertTrue(a && pro && b && anonymous, "saves: \(store.saves)")
        XCTAssertEqual(identityCalls, [
            .identify(userId: "user_a"),
            .logOut,
            .identify(userId: "user_b"),
            .logOut,
        ])
        XCTAssertFalse(galva.calledOnMainThread)
    }

    func test_logsConnectionThroughGalvaLogger() async throws {
        let run = startSync(followsRevenueCatIdentity: false)
        defer { run.cancel() }

        let connected = await eventually { self.logger.messages.contains("connected to RevenueCat") }
        XCTAssertTrue(connected)
        let entry = try XCTUnwrap(logger.entries.first { $0.message == "connected to RevenueCat" })
        XCTAssertEqual(entry.category, .integration)
        XCTAssertEqual(entry.metadata["revenueCatVersion"], "5.98.0")
        XCTAssertEqual(entry.metadata["identity"], "manual")
        XCTAssertEqual(entry.metadata["purchasesCompletedBy"], "revenueCat")
    }

    /// Galva's identity calls so far.
    private var identityCalls: [FakeGalva.Call] {
        galva.calls.filter { $0 != .reconcile && !Self.isTraits($0) }
    }

    /// Wait until the sync has sent traits `count` times.
    private func waitForTraits(_ count: Int) async -> Bool {
        await eventually { self.galva.calls.filter(Self.isTraits).count >= count }
    }

    // `CustomerSync` makes a step's Galva calls, then saves the mirrored
    // user, so tests that check the store wait for the save itself.

    // MARK: - Changes RevenueCat sends no update for

    func test_signUp_reachesGalvaOnTheNextTick_thoughRevenueCatSendsNoUpdate() async {
        let anonymous = RevenueCatCustomer.anonymous()
        revenueCat.start(as: anonymous)
        let run = await startFollowing()
        defer { run.cancel() }
        let connected = await waitForTraits(1)
        XCTAssertTrue(connected)
        // The app's `PurchasesDelegate` got the anonymous customer, which
        // RevenueCat counts as sent, as it does once its launch fetch has
        // sent it.
        revenueCat.setDelegate()

        revenueCat.signUp(as: "user_42")
        XCTAssertEqual(revenueCat.sent.count, 0, "the same customer, so RevenueCat sends nothing")
        app.tick()

        let identified = await eventually { self.store.saves == ["user_42"] }
        XCTAssertTrue(identified)
        XCTAssertEqual(identityCalls, [.identify(userId: "user_42")])
        let merged = anonymous.withUser(RevenueCatUser(appUserID: "user_42", isAnonymous: false))
        XCTAssertEqual(galva.calls.last, .setTraits(RevenueCatTraits(merged)), "the new user's attributes, from RevenueCat's cache")
    }

    func test_ticks_readOnlyTheAppUserID_untilItChanges() async {
        revenueCat.start(as: .identified("user_a"))
        let run = await startFollowing()
        defer { run.cancel() }
        XCTAssertEqual(revenueCat.snapshotReads, 1, "one full read, to connect")

        for _ in 0..<3 { app.tick() }
        let ticked = await eventually { self.revenueCat.appUserIDReads == 3 }
        XCTAssertTrue(ticked)
        XCTAssertEqual(revenueCat.snapshotReads, 1)

        revenueCat.logOut(to: "$RCAnonymousID:2")
        app.tick()
        let reread = await eventually { self.revenueCat.snapshotReads == 2 }
        XCTAssertTrue(reread, "a new app user ID is worth a full read")
    }

    func test_anUpdateFromBeforeRevenueCatsUserChanged_isReadAfresh() async {
        let anonymous = RevenueCatCustomer.anonymous()
        revenueCat.start(as: anonymous)
        let run = await startFollowing()
        defer { run.cancel() }
        revenueCat.setDelegate()
        revenueCat.signUp(as: "user_42")
        app.tick()
        let identified = await eventually { self.store.saves == ["user_42"] }
        XCTAssertTrue(identified)

        // The anonymous customer's update, sent before the sign-up.
        revenueCat.deliverLate(anonymous)

        let reread = await eventually { self.revenueCat.snapshotReads == 3 }
        XCTAssertTrue(reread)
        XCTAssertEqual(identityCalls, [.identify(userId: "user_42")], "a stale update doesn't log the new user out")
        XCTAssertEqual(store.saves, ["user_42"])
    }

    func test_logOutOffline_reachesGalvaOnTheNextTick_attributesWaitForRevenueCatsFetch() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: .identified("user_a"))
        let run = await startFollowing()
        defer { run.cancel() }
        let connected = await waitForTraits(1)
        XCTAssertTrue(connected)

        revenueCat.logOut(to: "$RCAnonymousID:2")
        app.tick()

        let loggedOut = await eventually { self.store.saves == [nil] }
        XCTAssertTrue(loggedOut)
        XCTAssertEqual(identityCalls, [.logOut])
        XCTAssertEqual(galva.calls.filter(Self.isTraits).count, 1, "nothing cached for the new anonymous user yet")

        // Back online, RevenueCat fetches its new user and sends it.
        revenueCat.fetched(.anonymous("$RCAnonymousID:2"))

        let synced = await waitForTraits(2)
        XCTAssertTrue(synced)
        XCTAssertEqual(galva.calls.last, .setTraits(RevenueCatTraits(.anonymous("$RCAnonymousID:2"))))
    }

    func test_manualIdentity_appSwitchesGalvaUsers_attributesResentWhenTheAppBecomesActive() async {
        galva.identity = GalvaIdentity(userId: "galva_1", appAccountToken: UUID())
        let customer = RevenueCatCustomer.identified("rc_1", entitlements: ["pro"])
        revenueCat.start(as: customer)
        let run = await startFollowing(followsRevenueCatIdentity: false)
        defer { run.cancel() }
        let first = await waitForTraits(1)
        XCTAssertTrue(first)
        // The app's `PurchasesDelegate` got the cached customer info, which
        // RevenueCat counts as sent.
        revenueCat.setDelegate()

        // The app calls `AppUser.logOut()` then `identify(userId: "galva_2")`.
        // RevenueCat's customer didn't change, so it sends nothing.
        galva.identity = GalvaIdentity(userId: "galva_2", appAccountToken: UUID())
        revenueCat.fetched(customer)
        XCTAssertEqual(revenueCat.sent.count, 0)

        app.becomeActive()

        let resent = await waitForTraits(2)
        XCTAssertTrue(resent, "the new Galva user gets the $gv_rc_* traits")
    }

    // MARK: - Connecting

    func test_connect_sendsCachedAttributes_andAPurchaseInRevenueCatsFirstUpdateReconciles() async {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let atLaunch = RevenueCatCustomer.identified("user_a", purchases: ["pro.month": day1])
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        revenueCat.start(as: atLaunch)
        let run = await startFollowing()
        defer { run.cancel() }
        let attributes = await waitForTraits(1)
        XCTAssertTrue(attributes, "sent from RevenueCat's cache, before any update")

        // The app sets its `PurchasesDelegate` after Galva connected, and
        // RevenueCat's launch fetch finds nothing new: no update.
        revenueCat.setDelegate()
        revenueCat.fetched(atLaunch)
        XCTAssertEqual(revenueCat.sent.count, 0)

        // Then a purchase from the app's own RevenueCat paywall: the first
        // update the sync sees.
        revenueCat.fetched(.identified("user_a", purchases: [
            "pro.month": day1,
            "pro.year": day1.addingTimeInterval(60),
        ]))

        let reconciled = await eventually { self.galva.calls.contains(.reconcile) }
        XCTAssertTrue(reconciled)
    }

    // MARK: - Identity across launches

    func test_launch_appliesALogOutTheSyncMissed_beforeRevenueCatEmits() async {
        // RevenueCat logged out just before the app quit, and relaunches
        // offline: it has no customer info for its new anonymous user, so it
        // sends nothing.
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: RevenueCatCustomer.anonymous().user)
        let run = startSync()
        defer { run.cancel() }

        let forgotten = await eventually { self.store.saves == [nil] }
        XCTAssertTrue(forgotten)
        XCTAssertEqual(galva.calls, [.logOut])
    }

    func test_launch_revenueCatStartsAsAnotherUser_logsGalvaOutFirst_beforeRevenueCatEmits() async {
        // The previous launch left Galva as user_a; RevenueCat starts as user_b.
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: RevenueCatCustomer.identified("user_b").user)
        let run = startSync()
        defer { run.cancel() }

        let mirrored = await eventually { self.store.saves == ["user_b"] }
        XCTAssertTrue(mirrored)
        XCTAssertEqual(galva.calls, [.logOut, .identify(userId: "user_b")])

        revenueCat.fetched(.identified("user_b"))

        let synced = await waitForTraits(1)
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [.logOut, .identify(userId: "user_b")], "not again for the update")
    }

    func test_launch_logOutTheSyncMissed_thenLogIn_identifiesTheNewUser() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: RevenueCatCustomer.anonymous().user)
        let run = await startFollowing()
        defer { run.cancel() }
        let loggedOut = await eventually { self.store.saves == [nil] }
        XCTAssertTrue(loggedOut)
        galva.identity = GalvaIdentity(userId: nil, appAccountToken: UUID())

        revenueCat.fetched(.anonymous())
        revenueCat.logIn(.identified("user_b"))

        let identified = await eventually { self.store.saves == [nil, "user_b"] }
        XCTAssertTrue(identified)
        XCTAssertEqual(identityCalls, [.logOut, .identify(userId: "user_b")])
    }

    func test_launch_galvaAlreadyRevenueCatsUser_makesNoIdentityCalls() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        revenueCat.start(as: RevenueCatCustomer.identified("user_a").user)
        let run = startSync()
        defer { run.cancel() }

        revenueCat.fetched(.identified("user_a"))

        let remembered = await eventually { self.store.saves == ["user_a"] }
        let synced = await waitForTraits(1)
        XCTAssertTrue(remembered, "remembered for the next launch")
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [])
    }

    func test_launch_revenueCatAnonymous_leavesTheAppsGalvaUserAlone() async {
        galva.identity = GalvaIdentity(userId: "app_user", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: RevenueCatCustomer.anonymous().user)
        let run = startSync()
        defer { run.cancel() }

        revenueCat.fetched(.anonymous())

        let forgotten = await eventually { self.store.saves == [nil] }
        let synced = await waitForTraits(1)
        XCTAssertTrue(forgotten)
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [])
    }

    func test_manualIdentity_makesNoIdentityCalls_andForgetsTheMirroredUser() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.start(as: RevenueCatCustomer.anonymous().user)
        let run = await startFollowing(followsRevenueCatIdentity: false)
        defer { run.cancel() }

        revenueCat.fetched(.anonymous())
        let first = await waitForTraits(1)
        revenueCat.logIn(.identified("user_b"))
        let second = await waitForTraits(2)

        let forgotten = await eventually { self.store.saves == [nil] }
        XCTAssertTrue(forgotten, "the sync mirrors nobody in .manual")
        XCTAssertTrue(first && second)
        XCTAssertEqual(identityCalls, [])
    }

    private static func isTraits(_ call: FakeGalva.Call) -> Bool {
        if case .setTraits = call { true } else { false }
    }
}
