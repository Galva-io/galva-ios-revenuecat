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
    @Locked var purchaseResult: Result<RevenueCatPurchaseOutcome, any Error> = .success(.cancelled)
    @Locked var storeKitLookupResult: Result<Bool, any Error> = .success(false)
    @Locked var syncError: (any Error)?
    /// What `latestTransactionID(for:)` returns, one per call; `nil` once
    /// they run out.
    @Locked var latestTransactionIDs: [UInt64?] = []

    @Locked private(set) var purchasedProductIds: [String] = []
    /// The promotional offer passed with each purchase, `nil` for none.
    @Locked private(set) var purchasedOfferIDs: [String?] = []
    @Locked private(set) var purchaseCalls: [PurchaseCall] = []
    @Locked private(set) var recordCount = 0
    @Locked private(set) var syncCount = 0
    @Locked private(set) var customerUpdatesCalls = 0
    @Locked private(set) var appUserIDReads = 0
    @Locked private(set) var snapshotReads = 0

    let frameworkVersion = "5.98.0"

    func purchase(productId: String, promotionalOfferID: String?) async throws -> RevenueCatPurchaseOutcome {
        $purchasedProductIds.withLock { $0.append(productId) }
        $purchasedOfferIDs.withLock { $0.append(promotionalOfferID) }
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

    // MARK: - Customer state

    // Modeled on RevenueCat's `CustomerInfoManager`: customer info is cached
    // per app user ID, and an update goes out only when the customer's data
    // differs from the last one sent (`sendUpdateIfChanged`). The app user ID
    // isn't part of that data, so a `logIn` that merges an anonymous user
    // into a new ID sends nothing.

    private struct CustomerState {
        var user = RevenueCatCustomer.anonymous().user
        var cache: [String: RevenueCatCustomer] = [:]
        var lastSent: RevenueCatCustomer?
        var observers: [AsyncStream<RevenueCatCustomer>.Continuation] = []
    }

    private let customerState = Locked(wrappedValue: CustomerState())

    /// Every update RevenueCat sent, in order.
    @Locked private(set) var sent: [RevenueCatCustomer] = []

    /// How many `customerUpdates()` streams are open.
    var observerCount: Int { customerState.withLock { $0.observers.count } }

    var currentAppUserID: String {
        $appUserIDReads.withLock { $0 += 1 }
        return customerState.withLock { $0.user.appUserID }
    }

    func snapshot() -> RevenueCatSnapshot {
        $snapshotReads.withLock { $0 += 1 }
        return customerState.withLock { state in
            state.cache[state.user.appUserID].map(RevenueCatSnapshot.init) ?? RevenueCatSnapshot(uncached: state.user)
        }
    }

    func customerUpdates() -> AsyncStream<RevenueCatCustomer> {
        $customerUpdatesCalls.withLock { $0 += 1 }
        let (stream, continuation) = AsyncStream<RevenueCatCustomer>.makeStream()
        customerState.withLock { state in
            // Like `customerInfoStream`, the last one sent comes first, with
            // RevenueCat's user as the live adapter reads it.
            if let lastSent = state.lastSent {
                continuation.yield(lastSent.withUser(state.user))
            }
            state.observers.append(continuation)
        }
        return stream
    }

    /// RevenueCat starts as `customer`'s user, with `customer` cached.
    /// Call before starting the sync.
    func start(as customer: RevenueCatCustomer) {
        customerState.withLock { $0 = CustomerState(user: customer.user, cache: [customer.appUserID: customer]) }
    }

    /// RevenueCat starts as `user`, with nothing cached for them, as offline
    /// right after a `logOut`. Call before starting the sync.
    func start(as user: RevenueCatUser) {
        customerState.withLock { $0 = CustomerState(user: user) }
    }

    /// RevenueCat fetched customer info for its current user, or a purchase
    /// changed it: cached, and sent if its data changed.
    func fetched(_ customer: RevenueCatCustomer) {
        update { state in
            precondition(customer.appUserID == state.user.appUserID, "RevenueCat fetches for its current user")
            state.cache[customer.appUserID] = customer
            return customer
        }
    }

    /// `Purchases.logIn` as `customer`'s user, which RevenueCat's server
    /// answers with `customer`. Sent if its data differs from the last
    /// customer's.
    func logIn(_ customer: RevenueCatCustomer) {
        update { state in
            state.user = customer.user
            state.cache = [customer.appUserID: customer]
            return customer
        }
    }

    /// `Purchases.logIn` with a new app user ID while anonymous, the usual
    /// sign-up: RevenueCat merges the anonymous user into it, so it's the
    /// same customer, with the same data, and nothing is sent.
    func signUp(as appUserID: String) {
        update { state in
            precondition(state.user.isAnonymous, "RevenueCat merges only an anonymous user into a new ID")
            let anonymous = state.cache[state.user.appUserID] ?? RevenueCatCustomer.anonymous(state.user.appUserID)
            var merged = anonymous
            merged.appUserID = appUserID
            merged.isAnonymous = false
            state.user = merged.user
            state.cache = [appUserID: merged]
            return merged
        }
    }

    /// `Purchases.logOut`: a new anonymous user, with nothing cached for
    /// them. Nothing is sent until RevenueCat has fetched them.
    func logOut(to anonymousID: String = "$RCAnonymousID:9f8e7d") {
        customerState.withLock { state in
            state.user = RevenueCatCustomer.anonymous(anonymousID).user
            state.cache = [:]
        }
    }

    /// The app sets a `PurchasesDelegate`: RevenueCat hands it the cached
    /// customer info and counts it as sent, without telling stream
    /// listeners (`sendCachedCustomerInfoToDelegateIfExists`).
    func setDelegate() {
        customerState.withLock { state in
            if let cached = state.cache[state.user.appUserID] { state.lastSent = cached }
        }
    }

    /// An update RevenueCat sent before its user changed, reaching the sync
    /// only now.
    func deliverLate(_ customer: RevenueCatCustomer) {
        customerState.withLock { state in
            for observer in state.observers {
                observer.yield(customer)
            }
        }
    }

    /// Apply `change`, then send the customer it returns if its data differs
    /// from the last one sent.
    private func update(_ change: (inout CustomerState) -> RevenueCatCustomer) {
        customerState.withLock { state in
            let customer = change(&state)
            if let lastSent = state.lastSent, lastSent.hasSameData(as: customer) { return }
            state.lastSent = customer
            $sent.withLock { $0.append(customer) }
            for observer in state.observers {
                observer.yield(customer)
            }
        }
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

/// App signals the test drives by hand; records `stop()`.
final class FakeApp: @unchecked Sendable {
    let signals: AppSignals
    private let continuation: AsyncStream<AppSignals.Signal>.Continuation
    private let stoppedFlag: Locked<Bool>

    init() {
        let (stream, continuation) = AsyncStream<AppSignals.Signal>.makeStream()
        let stoppedFlag = Locked(wrappedValue: false)
        self.continuation = continuation
        self.stoppedFlag = stoppedFlag
        signals = AppSignals(signals: stream, stop: {
            stoppedFlag.wrappedValue = true
            continuation.finish()
        })
    }

    var stopped: Bool { stoppedFlag.wrappedValue }

    func becomeActive() {
        continuation.yield(.activated)
    }

    func tick() {
        continuation.yield(.tick)
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

    /// The same customer data, for `user`.
    func withUser(_ user: RevenueCatUser) -> Self {
        var customer = self
        customer.appUserID = user.appUserID
        customer.isAnonymous = user.isAnonymous
        return customer
    }

    /// Whether RevenueCat would see no change: the same customer data,
    /// whoever its user is.
    func hasSameData(as other: Self) -> Bool {
        originalAppUserID == other.originalAppUserID
            && activeEntitlements == other.activeEntitlements
            && purchaseDates == other.purchaseDates
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
