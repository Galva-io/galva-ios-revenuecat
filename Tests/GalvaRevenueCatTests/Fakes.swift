//
//  Fakes.swift
//  GalvaRevenueCatTests
//
//  Recording stand-ins for the adapters. Lock-backed, so they're `Sendable`
//  like the live adapters and safe to touch from any actor.
//

import Foundation
import Galva
@testable import GalvaRevenueCat
import RevenueCat
import StoreKit

/// A value guarded by a lock.
@propertyWrapper
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }

    var projectedValue: Locked<Value> { self }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class FakeRevenueCat: RevenueCatAdapter, @unchecked Sendable {
    @Locked var isConfigured = true
    @Locked var appCompletesPurchases = false
    @Locked var purchaseResult: Result<RevenueCatPurchaseOutcome, any Error> = .success(.cancelled)
    @Locked var recordError: (any Error)?
    @Locked var syncError: (any Error)?
    @Locked var latest: StoreKit.Transaction?

    @Locked private(set) var purchasedProductIds: [String] = []
    @Locked private(set) var recordCount = 0
    @Locked private(set) var syncCount = 0
    @Locked private(set) var customerUpdatesCalls = 0

    let frameworkVersion = "5.98.0"
    let updates: AsyncStream<RevenueCatCustomer>
    let updatesContinuation: AsyncStream<RevenueCatCustomer>.Continuation

    init() {
        (updates, updatesContinuation) = AsyncStream.makeStream()
    }

    func purchase(productId: String) async throws -> RevenueCatPurchaseOutcome {
        $purchasedProductIds.withLock { $0.append(productId) }
        return try purchaseResult.get()
    }

    func recordPurchase(_ result: Product.PurchaseResult) async throws {
        $recordCount.withLock { $0 += 1 }
        if let recordError { throw recordError }
    }

    func syncPurchases() async throws {
        $syncCount.withLock { $0 += 1 }
        if let syncError { throw syncError }
    }

    func latestTransaction(for productId: String) async -> StoreKit.Transaction? {
        latest
    }

    func customerUpdates() -> AsyncStream<RevenueCatCustomer> {
        $customerUpdatesCalls.withLock { $0 += 1 }
        return updates
    }
}

final class FakeGalva: GalvaAdapter, @unchecked Sendable {
    enum Call: Equatable {
        case identify(userId: String, appAccountToken: UUID?)
        case logOut
        case setTraits(RevenueCatTraits)
        case reconcile
    }

    @Locked private(set) var calls: [Call] = []
    /// Whether any call arrived on the main thread.
    @Locked private(set) var calledOnMainThread = false

    func identify(userId: String, appAccountToken: UUID?) {
        if Thread.isMainThread { calledOnMainThread = true }
        $calls.withLock { $0.append(.identify(userId: userId, appAccountToken: appAccountToken)) }
    }

    func logOut() {
        $calls.withLock { $0.append(.logOut) }
    }

    func setTraits(_ traits: RevenueCatTraits) {
        $calls.withLock { $0.append(.setTraits(traits)) }
    }

    func reconcileTransactions() {
        $calls.withLock { $0.append(.reconcile) }
    }
}

/// Foreground signals the test drives by hand; records `stop()`.
final class FakeForeground: @unchecked Sendable {
    let signals: ForegroundSignals
    private let continuation: AsyncStream<Void>.Continuation
    private let stoppedFlag: Locked<Bool>

    init() {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let stoppedFlag = Locked(wrappedValue: false)
        self.continuation = continuation
        self.stoppedFlag = stoppedFlag
        signals = ForegroundSignals(events: events, stop: {
            stoppedFlag.wrappedValue = true
            continuation.finish()
        })
    }

    var stopped: Bool { stoppedFlag.wrappedValue }

    func becomeActive() {
        continuation.yield()
    }

    func endWithoutStop() {
        continuation.finish()
    }
}

final class RecordingLogger: GalvaLogger, @unchecked Sendable {
    @Locked private(set) var entries: [Galva.LogEntry] = []

    func log(_ entry: Galva.LogEntry) {
        $entries.withLock { $0.append(entry) }
    }

    var messages: [String] { entries.map(\.message) }
}

extension RevenueCatCustomer {
    static func identified(
        _ id: String,
        entitlements: [String] = [],
        purchases: [String: Date] = [:]
    ) -> Self {
        .init(
            appUserID: id,
            isAnonymous: false,
            originalAppUserID: id,
            activeEntitlements: entitlements,
            purchaseDates: purchases
        )
    }

    static func anonymous(_ id: String = "$RCAnonymousID:0a1b2c") -> Self {
        .init(appUserID: id, isAnonymous: true, originalAppUserID: id, activeEntitlements: [], purchaseDates: [:])
    }
}

/// Polls `condition` until it holds or about two seconds pass.
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
