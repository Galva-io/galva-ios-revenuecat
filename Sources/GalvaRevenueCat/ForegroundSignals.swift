//
//  ForegroundSignals.swift
//  GalvaRevenueCat
//
//  "The app became active" events: the moments the integration re-checks
//  whether RevenueCat has been configured yet. `CustomerSync` calls `stop()`
//  as soon as it connects, which removes the observer — leaving the
//  `for await` loop alone wouldn't.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ForegroundSignals: Sendable {

    let events: AsyncStream<Void>
    /// Ends `events` and stops observing.
    let stop: @Sendable () -> Void

    /// Driven by the app's didBecomeActive notification.
    static func app() -> ForegroundSignals {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = ObserverToken(NotificationCenter.default.addObserver(
            forName: didBecomeActive,
            object: nil,
            queue: nil
        ) { _ in
            continuation.yield()
        })
        continuation.onTermination = { _ in
            NotificationCenter.default.removeObserver(observer.token)
        }
        return ForegroundSignals(events: events, stop: { continuation.finish() })
    }

    #if canImport(UIKit)
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #elseif canImport(AppKit)
    private static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #endif
}

/// Carries the observer token into the `@Sendable` termination handler.
private final class ObserverToken: @unchecked Sendable {
    let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }
}
