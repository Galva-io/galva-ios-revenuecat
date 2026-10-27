//
//  RevenueCatAdapter.swift
//  GalvaRevenueCat
//
//  The slice of RevenueCat this package uses, and the StoreKit lookups next
//  to it, behind a protocol so purchase routing and the customer sync are
//  testable without a configured `Purchases`. Not tied to any actor:
//  `Purchases` is thread-safe, and its async APIs do their work off the main
//  thread.
//

import Foundation
import RevenueCat
import StoreKit

/// Who RevenueCat's user is.
struct RevenueCatUser: Sendable, Equatable {
    var appUserID: String
    var isAnonymous: Bool
}

/// RevenueCat customer state, from a `CustomerInfo`: one RevenueCat sent, or
/// the one it has cached for its user.
struct RevenueCatCustomer: Sendable {
    var appUserID: String
    var isAnonymous: Bool
    var originalAppUserID: String
    /// Identifiers of the active entitlements, sorted.
    var activeEntitlements: [String]
    /// Latest purchase date per purchased product.
    var purchaseDates: [String: Date]

    var user: RevenueCatUser {
        RevenueCatUser(appUserID: appUserID, isAnonymous: isAnonymous)
    }
}

/// RevenueCat's user, read together with the customer info it has cached
/// for them.
struct RevenueCatSnapshot: Sendable {
    let user: RevenueCatUser
    /// `nil` until RevenueCat has fetched customer info for `user`, as for
    /// the anonymous user a `logOut` creates, while offline.
    let customer: RevenueCatCustomer?

    init(_ customer: RevenueCatCustomer) {
        user = customer.user
        self.customer = customer
    }

    init(uncached user: RevenueCatUser) {
        self.user = user
        customer = nil
    }
}

/// How a purchase made with RevenueCat's own API ended. Pending and failures
/// arrive as thrown `ErrorCode`s, the way RevenueCat reports them.
enum RevenueCatPurchaseOutcome: Sendable {
    /// Purchased. The StoreKit 2 transaction when RevenueCat exposes one.
    case completed(StoreKit.Transaction?)
    case cancelled
    /// RevenueCat returned no product for the id, so nothing was bought. It
    /// swallows the lookup's error, so this doesn't say why.
    case productNotFound
}

protocol RevenueCatAdapter: Sendable {
    /// `false` until `Purchases.configure(...)` runs. Everything else touches
    /// `Purchases.shared`, which traps before that — check this first.
    var isConfigured: Bool { get }
    /// `true` when the app finishes transactions itself
    /// (`purchasesAreCompletedBy: .myApp`).
    var appCompletesPurchases: Bool { get }
    var frameworkVersion: String { get }
    /// RevenueCat's app user ID right now. RevenueCat keeps it in memory, so
    /// this is cheap enough to poll.
    var currentAppUserID: String { get }
    /// RevenueCat's user right now, with the customer info it has cached for
    /// them. The user is known as soon as RevenueCat is configured, even
    /// offline; the customer info once RevenueCat has fetched it for them.
    func snapshot() -> RevenueCatSnapshot
    func purchase(productId: String) async throws -> RevenueCatPurchaseOutcome
    /// Looks the product up with StoreKit directly: `false` when the App
    /// Store doesn't sell it, StoreKit's error when the lookup fails.
    func storeKitHasProduct(_ productId: String) async throws -> Bool
    func recordPurchase(_ result: Product.PurchaseResult) async throws
    func syncPurchases() async throws
    /// The product's latest verified StoreKit transaction.
    func latestTransaction(for productId: String) async -> StoreKit.Transaction?
    /// Its id: enough to tell whether StoreKit has a new one, and, unlike
    /// a `StoreKit.Transaction`, something tests can stand in for.
    func latestTransactionID(for productId: String) async -> UInt64?
    /// The customer info RevenueCat last sent, if any, then each one it
    /// sends. RevenueCat sends one only when the customer's data differs
    /// from the last one it sent, so a new app user ID alone doesn't produce
    /// one: a `logIn` that merges an anonymous user into a new ID, the usual
    /// sign-up, keeps the same customer.
    func customerUpdates() -> AsyncStream<RevenueCatCustomer>
}

struct LiveRevenueCatAdapter: RevenueCatAdapter {

    var isConfigured: Bool { Purchases.isConfigured }

    var appCompletesPurchases: Bool { Purchases.shared.purchasesAreCompletedBy == .myApp }

    var frameworkVersion: String { Purchases.frameworkVersion }

    var currentAppUserID: String { Purchases.shared.appUserID }

    func snapshot() -> RevenueCatSnapshot {
        let purchases = Purchases.shared
        // `cachedCustomerInfo` is for whoever RevenueCat's user is as it's
        // read. Reading the ID on both sides keeps the two together; a read
        // that straddles a `logIn` or `logOut` is tried again.
        for _ in 0..<3 {
            let user = Self.currentUser(purchases)
            let info = purchases.cachedCustomerInfo
            guard purchases.appUserID == user.appUserID else { continue }
            return info.map { RevenueCatSnapshot(RevenueCatCustomer(user: user, info: $0)) }
                ?? RevenueCatSnapshot(uncached: user)
        }
        return RevenueCatSnapshot(uncached: Self.currentUser(purchases))
    }

    func purchase(productId: String) async throws -> RevenueCatPurchaseOutcome {
        let products = await Purchases.shared.products([productId])
        guard let product = products.first(where: { $0.productIdentifier == productId }) else {
            return .productNotFound
        }
        let result = try await Purchases.shared.purchase(product: product)
        if result.userCancelled { return .cancelled }
        return .completed(result.transaction?.sk2Transaction)
    }

    func storeKitHasProduct(_ productId: String) async throws -> Bool {
        try await Product.products(for: [productId]).contains { $0.id == productId }
    }

    func recordPurchase(_ result: Product.PurchaseResult) async throws {
        _ = try await Purchases.shared.recordPurchase(result)
    }

    func syncPurchases() async throws {
        _ = try await Purchases.shared.syncPurchases()
    }

    func latestTransaction(for productId: String) async -> StoreKit.Transaction? {
        guard case .verified(let transaction)? = await StoreKit.Transaction.latest(for: productId) else {
            return nil
        }
        return transaction
    }

    func latestTransactionID(for productId: String) async -> UInt64? {
        await latestTransaction(for: productId)?.id
    }

    func customerUpdates() -> AsyncStream<RevenueCatCustomer> {
        let purchases = Purchases.shared
        return AsyncStream { continuation in
            // `customerInfoStream` registers a fresh observer per stream, so
            // this never competes with the app's own `PurchasesDelegate` or
            // stream consumers.
            let task = Task {
                for await info in purchases.customerInfoStream {
                    continuation.yield(RevenueCatCustomer(user: Self.currentUser(purchases), info: info))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func currentUser(_ purchases: Purchases) -> RevenueCatUser {
        RevenueCatUser(appUserID: purchases.appUserID, isAnonymous: purchases.isAnonymous)
    }
}

private extension RevenueCatCustomer {
    init(user: RevenueCatUser, info: CustomerInfo) {
        var purchaseDates: [String: Date] = [:]
        for productID in info.allPurchasedProductIdentifiers {
            purchaseDates[productID] = info.purchaseDate(forProductIdentifier: productID)
        }
        self.init(
            appUserID: user.appUserID,
            isAnonymous: user.isAnonymous,
            originalAppUserID: info.originalAppUserId,
            activeEntitlements: info.entitlements.active.keys.sorted(),
            purchaseDates: purchaseDates
        )
    }
}
