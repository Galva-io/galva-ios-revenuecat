//
//  AppSignals.swift
//  GalvaRevenueCat
//
//  The moments the integration reads RevenueCat again: each time the app
//  becomes active, and every two seconds while it stays active. Nothing
//  ticks while the app isn't active.
//
//  RevenueCat has no way to observe its user. Its updates follow the
//  customer's data, so a sign-up that keeps the same customer under a new
//  app user ID sends none; reading the app user ID every two seconds is how
//  the integration notices.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AppSignals: Sendable {

    enum Signal: Sendable, Equatable {
        /// The app became active.
        case activated
        /// Another interval passed with the app active.
        case tick
    }

    let signals: AsyncStream<Signal>
    /// Ends `signals`, stops the timer and stops observing the app.
    let stop: @Sendable () -> Void

    /// Driven by the app's didBecomeActive and willResignActive
    /// notifications. Ticks every `interval` seconds in between, and from
    /// the start when the app is already active.
    static func app(
        tickingEvery interval: TimeInterval = 2,
        center: NotificationCenter = .default,
        isActive: @escaping @MainActor @Sendable () -> Bool = { AppSignals.isAppActive }
    ) -> AppSignals {
        let (signals, continuation) = AsyncStream<Signal>.makeStream()
        let ticker = Ticker(interval: interval) { continuation.yield(.tick) }
        let observers = Observers(center: center, tokens: [
            center.addObserver(forName: didBecomeActive, object: nil, queue: nil) { _ in
                continuation.yield(.activated)
                ticker.start()
            },
            center.addObserver(forName: willResignActive, object: nil, queue: nil) { _ in
                ticker.pause()
            },
        ])
        // Galva can be configured after the app became active, so it may
        // never see the notification.
        Task { @MainActor in
            if isActive() { ticker.start() }
        }
        continuation.onTermination = { _ in
            observers.remove()
            ticker.stop()
        }
        return AppSignals(signals: signals, stop: { continuation.finish() })
    }

    #if canImport(UIKit)
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    static let willResignActive = UIApplication.willResignActiveNotification

    @MainActor static var isAppActive: Bool { UIApplication.shared.applicationState == .active }
    #elseif canImport(AppKit)
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    static let willResignActive = NSApplication.willResignActiveNotification

    @MainActor static var isAppActive: Bool { NSApplication.shared.isActive }
    #endif
}

/// Calls `tick` every `interval` seconds between `start()` and `pause()`.
private final class Ticker: @unchecked Sendable {
    private let interval: TimeInterval
    private let tick: @Sendable () -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isStopped = false

    init(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.tick = tick
    }

    /// Start ticking, unless it already is or has stopped for good.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil, !isStopped else { return }
        let nanoseconds = UInt64(interval * 1_000_000_000)
        task = Task { [tick] in
            while true {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                tick()
            }
        }
    }

    /// Stop ticking until the next `start()`.
    func pause() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    /// Stop ticking for good.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        isStopped = true
        task?.cancel()
        task = nil
    }
}

/// Carries the observer tokens into the `@Sendable` termination handler.
private final class Observers: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [any NSObjectProtocol]

    init(center: NotificationCenter, tokens: [any NSObjectProtocol]) {
        self.center = center
        self.tokens = tokens
    }

    func remove() {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
