//
//  CustomerSyncTests.swift
//  GalvaRevenueCatTests
//
//  The `CustomerSync` actor: waits for RevenueCat to be configured, matches
//  Galva to RevenueCat's user as it connects, applies updates in order, off
//  the main thread, carries identity across launches, and logs through
//  Galva's logger.
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
    private var foreground: FakeForeground!

    override func setUp() {
        revenueCat = FakeRevenueCat()
        galva = FakeGalva()
        store = FakeMirroredUserStore()
        logger = RecordingLogger()
        foreground = FakeForeground()
    }

    private func startSync(followsRevenueCatIdentity: Bool = true) -> Task<Void, Never> {
        let sync = CustomerSync(
            followsRevenueCatIdentity: followsRevenueCatIdentity,
            galva: galva,
            store: store,
            logger: logger
        )
        let revenueCat = revenueCat!
        let signals = foreground.signals
        return Task { await sync.run(revenueCat: revenueCat, foregrounds: signals) }
    }

    func test_waitsUntilRevenueCatIsConfigured_thenSyncs() async {
        revenueCat.isConfigured = false
        revenueCat.currentUser = RevenueCatCustomer.identified("user_42").user
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.identified("user_42"))
        foreground.becomeActive()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(revenueCat.customerUpdatesCalls, 0, "must not touch RevenueCat before it's configured")
        XCTAssertEqual(galva.calls, [], "nor match Galva to its user")
        XCTAssertFalse(foreground.stopped)
        XCTAssertTrue(logger.messages.contains { $0.contains("isn't configured yet") })

        revenueCat.isConfigured = true
        foreground.becomeActive()

        let identified = await eventually {
            self.galva.calls.contains(.identify(userId: "user_42", appAccountToken: nil))
        }
        XCTAssertTrue(identified)
        XCTAssertTrue(foreground.stopped, "stops observing foregrounds once connected")
    }

    func test_alreadyConfigured_stopsObservingForegroundsRightAway() async {
        let run = startSync()
        defer { run.cancel() }

        let stopped = await eventually { self.foreground.stopped }

        XCTAssertTrue(stopped)
    }

    func test_stopsWaitingWhenForegroundSignalsEnd() async {
        revenueCat.isConfigured = false
        let run = startSync()

        foreground.endWithoutStop()
        await run.value

        XCTAssertEqual(revenueCat.customerUpdatesCalls, 0)
    }

    func test_appliesUpdatesInOrder_offTheMainThread() async {
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.identified("user_a"))
        revenueCat.updatesContinuation.yield(.identified("user_b"))
        revenueCat.updatesContinuation.yield(.anonymous())

        let done = await eventually { self.galva.calls.filter { $0 == .logOut }.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(galva.calls.filter { $0 != .reconcile && !Self.isTraits($0) }, [
            .identify(userId: "user_a", appAccountToken: nil),
            .logOut,
            .identify(userId: "user_b", appAccountToken: nil),
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

    // MARK: - Identity across launches

    /// Galva's identity calls so far.
    private var identityCalls: [FakeGalva.Call] {
        galva.calls.filter { $0 != .reconcile && !Self.isTraits($0) }
    }

    /// Wait until the sync has handled `count` updates: each sends traits
    /// the first time.
    private func waitForTraits(_ count: Int) async -> Bool {
        await eventually { self.galva.calls.filter(Self.isTraits).count >= count }
    }

    // `CustomerSync` makes a step's Galva calls, then saves the mirrored
    // user, so tests that check the store wait for the save itself.

    func test_launch_appliesALogOutTheSyncMissed_beforeRevenueCatEmits() async {
        // RevenueCat logged out offline and relaunches offline: it has no
        // customer info for its new anonymous user, so it emits nothing.
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.currentUser = RevenueCatCustomer.anonymous().user
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
        revenueCat.currentUser = RevenueCatCustomer.identified("user_b").user
        let run = startSync()
        defer { run.cancel() }

        let mirrored = await eventually { self.store.saves == ["user_b"] }
        XCTAssertTrue(mirrored)
        XCTAssertEqual(galva.calls, [.logOut, .identify(userId: "user_b", appAccountToken: nil)])

        revenueCat.updatesContinuation.yield(.identified("user_b"))

        let synced = await waitForTraits(1)
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [.logOut, .identify(userId: "user_b", appAccountToken: nil)], "not again for the update")
    }

    func test_launch_logOutTheSyncMissed_thenLogIn_identifiesTheNewUser() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.currentUser = RevenueCatCustomer.anonymous().user
        let run = startSync()
        defer { run.cancel() }
        let loggedOut = await eventually { self.store.saves == [nil] }
        XCTAssertTrue(loggedOut)
        galva.identity = GalvaIdentity(userId: nil, appAccountToken: UUID())

        revenueCat.updatesContinuation.yield(.anonymous())
        revenueCat.updatesContinuation.yield(.identified("user_b"))

        let identified = await eventually { self.store.saves == [nil, "user_b"] }
        XCTAssertTrue(identified)
        XCTAssertEqual(identityCalls, [.logOut, .identify(userId: "user_b", appAccountToken: nil)])
    }

    func test_launch_galvaAlreadyRevenueCatsUser_makesNoIdentityCalls() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        revenueCat.currentUser = RevenueCatCustomer.identified("user_a").user
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.identified("user_a"))

        let remembered = await eventually { self.store.saves == ["user_a"] }
        let synced = await waitForTraits(1)
        XCTAssertTrue(remembered, "remembered for the next launch")
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [])
    }

    func test_launch_revenueCatAnonymous_leavesTheAppsGalvaUserAlone() async {
        galva.identity = GalvaIdentity(userId: "app_user", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.currentUser = RevenueCatCustomer.anonymous().user
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.anonymous())

        let forgotten = await eventually { self.store.saves == [nil] }
        let synced = await waitForTraits(1)
        XCTAssertTrue(forgotten)
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [])
    }

    func test_persistsEveryChangeOfTheMirroredUser() async {
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.identified("user_a"))
        revenueCat.updatesContinuation.yield(.identified("user_a", entitlements: ["pro"]))
        revenueCat.updatesContinuation.yield(.identified("user_b"))
        revenueCat.updatesContinuation.yield(.anonymous())

        let done = await eventually { self.store.saves == ["user_a", "user_b", nil] }
        XCTAssertTrue(done, "saves: \(store.saves)")
    }

    func test_manualIdentity_makesNoIdentityCalls_andForgetsTheMirroredUser() async {
        galva.identity = GalvaIdentity(userId: "user_a", appAccountToken: UUID())
        store.appUserID = "user_a"
        revenueCat.currentUser = RevenueCatCustomer.anonymous().user
        let run = startSync(followsRevenueCatIdentity: false)
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.anonymous())
        revenueCat.updatesContinuation.yield(.identified("user_b"))

        let forgotten = await eventually { self.store.saves == [nil] }
        let synced = await waitForTraits(2)
        XCTAssertTrue(forgotten, "the sync mirrors nobody in .manual")
        XCTAssertTrue(synced)
        XCTAssertEqual(identityCalls, [])
    }

    // MARK: - Traits

    func test_manualIdentity_resendsTraitsAfterTheAppSwitchesGalvaUsers() async {
        galva.identity = GalvaIdentity(userId: "galva_1", appAccountToken: UUID())
        let run = startSync(followsRevenueCatIdentity: false)
        defer { run.cancel() }
        let customer = RevenueCatCustomer.identified("rc_1", entitlements: ["pro"])

        revenueCat.updatesContinuation.yield(customer)
        let first = await waitForTraits(1)
        XCTAssertTrue(first)

        // The app calls `AppUser.logOut()` then `identify(userId: "galva_2")`.
        galva.identity = GalvaIdentity(userId: "galva_2", appAccountToken: UUID())
        revenueCat.updatesContinuation.yield(customer)

        let resent = await waitForTraits(2)
        XCTAssertTrue(resent, "the new Galva user gets the $gv_rc_* traits")
    }

    private static func isTraits(_ call: FakeGalva.Call) -> Bool {
        if case .setTraits = call { true } else { false }
    }
}
