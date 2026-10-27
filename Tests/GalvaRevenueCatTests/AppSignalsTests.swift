//
//  AppSignalsTests.swift
//  GalvaRevenueCatTests
//
//  `AppSignals.app`: a signal each time the app becomes active, ticks while
//  it stays active and none after it resigns, ticks from the start when
//  it's already active, and an end when stopped. Driven through a private
//  notification center, with 20 ms ticks.
//

import Foundation
@testable import GalvaRevenueCat
import XCTest

final class AppSignalsTests: XCTestCase {

    private let center = NotificationCenter()
    private let interval: TimeInterval = 0.02

    func test_signalsEachActivation_thenTicksUntilTheAppResignsActive() async {
        let app = AppSignals.app(tickingEvery: interval, center: center, isActive: { false })
        defer { app.stop() }
        let received = collect(app.signals)

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(received.wrappedValue, [], "nothing before the app becomes active")

        center.post(name: AppSignals.didBecomeActive, object: nil)
        let ticking = await eventually { received.wrappedValue.filter { $0 == .tick }.count >= 3 }
        XCTAssertTrue(ticking)
        XCTAssertEqual(received.wrappedValue.first, .activated)

        center.post(name: AppSignals.willResignActive, object: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let countAfterResigning = received.wrappedValue.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(received.wrappedValue.count, countAfterResigning, "no ticks while the app isn't active")
    }

    func test_alreadyActive_ticksWithoutAnActivation() async {
        let app = AppSignals.app(tickingEvery: interval, center: center, isActive: { true })
        defer { app.stop() }
        let received = collect(app.signals)

        let ticking = await eventually { received.wrappedValue.count >= 2 }

        XCTAssertTrue(ticking)
        XCTAssertFalse(received.wrappedValue.contains(.activated))
    }

    func test_stop_endsTheSignals() async {
        let app = AppSignals.app(tickingEvery: interval, center: center, isActive: { true })
        let iterating = Task {
            for await _ in app.signals {}
        }

        app.stop()

        await iterating.value
    }

    /// Collects `signals` as they arrive, for the rest of the test.
    private func collect(_ signals: AsyncStream<AppSignals.Signal>) -> Locked<[AppSignals.Signal]> {
        let received = Locked(wrappedValue: [AppSignals.Signal]())
        let task = Task {
            for await signal in signals {
                received.withLock { $0.append(signal) }
            }
        }
        addTeardownBlock { task.cancel() }
        return received
    }
}
