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
    /// The purchase-path calls, in the order they were made.
    enum PurchaseCall: Equatable {
        case latestTransaction
        case latestTransactionID
        case purchase
        case storeKitLookup
    }

    @Locked var isConfigured = true
    @Locked var appCompletesPurchases = false
    /// RevenueCat's user when the sync connects. Tests that start RevenueCat
    /// as someone set it before starting the sync.
    @Locked var currentUser = RevenueCatCustomer.anonymous().user
    @Locked var purchaseResult: Result<RevenueCatPurchaseOutcome, any Error> = .success(.cancelled)
    @Locked var storeKitLookupResult: Result<Bool, any Error> = .success(false)
    @Locked var syncError: (any Error)?
    /// What `latestTransactionID(for:)` returns, one per call; `nil` once
    /// they run out.
    @Locked var latestTransactionIDs: [UInt64?] = []

    @Locked private(set) var purchasedProductIds: [String] = []
    @Locked private(set) var purchaseCalls: [PurchaseCall] = []
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
        $purchaseCalls.withLock { $0.append(.purchase) }
        return try purchaseResult.get()
    }

    func storeKitHasProduct(_ productId: String) async throws -> Bool {
        $purchaseCalls.withLock { $0.append(.storeKitLookup) }
        return try storeKitLookupResult.get()
    }

    func recordPurchase(_ result: Product.PurchaseResult) async throws {
        $recordCount.withLock { $0 += 1 }
    }

    func syncPurchases() async throws {
        $syncCount.withLock { $0 += 1 }
        if let syncError { throw syncError }
    }

    /// Always `nil`: a `StoreKit.Transaction` can only come from a real
    /// purchase.
    func latestTransaction(for productId: String) async -> StoreKit.Transaction? {
        $purchaseCalls.withLock { $0.append(.latestTransaction) }
        return nil
    }

    func latestTransactionID(for productId: String) async -> UInt64? {
        $purchaseCalls.withLock { $0.append(.latestTransactionID) }
        return $latestTransactionIDs.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    func customerUpdates() -> AsyncStream<RevenueCatCustomer> {
        $customerUpdatesCalls.withLock { $0 += 1 }
        return updates
    }
}

final class FakeGalva: GalvaAdapter, @unchecked Sendable {
    enum Call: Equatable {
        case identify(userId: String)
        case logOut
        case setTraits(RevenueCatTraits)
        case reconcile
    }

    /// Galva's user as `AppUser` reports it. Tests set it; the fake's
    /// `identify` and `logOut` leave it alone.
    @Locked var identity = GalvaIdentity(userId: nil, appAccountToken: UUID())
    @Locked private(set) var calls: [Call] = []
    /// Whether any call arrived on the main thread.
    @Locked private(set) var calledOnMainThread = false

    func identify(userId: String) {
        record(.identify(userId: userId))
    }

    func logOut() {
        record(.logOut)
    }

    func setTraits(_ traits: RevenueCatTraits) {
        record(.setTraits(traits))
    }

    func reconcileTransactions() {
        record(.reconcile)
    }

    private func record(_ call: Call) {
        if Thread.isMainThread { calledOnMainThread = true }
        $calls.withLock { $0.append(call) }
    }
}

/// An in-memory `MirroredUserStore`, standing in for `UserDefaults`.
final class FakeMirroredUserStore: MirroredUserStore, @unchecked Sendable {
    /// What the previous launch left; tests set it before starting a sync.
    @Locked var appUserID: String? = nil
    /// Every value saved, in order.
    @Locked private(set) var saves: [String?] = []

    func load() -> String? {
        appUserID
    }

    func save(_ appUserID: String?) {
        self.appUserID = appUserID
        $saves.withLock { $0.append(appUserID) }
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
