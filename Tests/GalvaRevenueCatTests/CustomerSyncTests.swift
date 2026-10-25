//
//  CustomerSyncTests.swift
//  GalvaRevenueCatTests
//
//  The `CustomerSync` actor: waits for RevenueCat to be configured, applies
//  updates in order, off the main thread, and logs through Galva's logger.
//

import Foundation
import Galva
@testable import GalvaRevenueCat
import XCTest

final class CustomerSyncTests: XCTestCase {

    private var revenueCat: FakeRevenueCat!
    private var galva: FakeGalva!
    private var logger: RecordingLogger!
    private var foreground: FakeForeground!

    override func setUp() {
        revenueCat = FakeRevenueCat()
        galva = FakeGalva()
        logger = RecordingLogger()
        foreground = FakeForeground()
    }

    private func startSync(followsRevenueCatIdentity: Bool = true) -> Task<Void, Never> {
        let sync = CustomerSync(
            followsRevenueCatIdentity: followsRevenueCatIdentity,
            galva: galva,
            logger: logger
        )
        let revenueCat = revenueCat!
        let signals = foreground.signals
        return Task { await sync.run(revenueCat: revenueCat, foregrounds: signals) }
    }

    func test_waitsUntilRevenueCatIsConfigured_thenSyncs() async {
        revenueCat.isConfigured = false
        let run = startSync()
        defer { run.cancel() }

        revenueCat.updatesContinuation.yield(.identified("user_42"))
        foreground.becomeActive()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(revenueCat.customerUpdatesCalls, 0, "must not touch RevenueCat before it's configured")
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

    private static func isTraits(_ call: FakeGalva.Call) -> Bool {
        if case .setTraits = call { true } else { false }
    }
}
