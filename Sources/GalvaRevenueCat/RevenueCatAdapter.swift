//
//  RevenueCatAdapter.swift
//  GalvaRevenueCat
//
//  The slice of RevenueCat this package uses, behind a protocol so purchase
//  routing and the customer sync are testable without a configured
//  `Purchases`. Not tied to any actor: `Purchases` is thread-safe, and its
//  async APIs do their work off the main thread.
//

import Foundation
import RevenueCat
import StoreKit

/// RevenueCat customer state, captured on every `CustomerInfo` update.
struct RevenueCatCustomer: Sendable, Equatable {
    var appUserID: String
    var isAnonymous: Bool
    var originalAppUserID: String
    /// Identifiers of the active entitlements, sorted.
    var activeEntitlements: [String]
    /// Latest purchase date per purchased product.
    var purchaseDates: [String: Date]
}

/// How a purchase made with RevenueCat's own API ended. Pending and failures
/// arrive as thrown `ErrorCode`s, the way RevenueCat reports them.
enum RevenueCatPurchaseOutcome: Sendable {
    /// Purchased. The StoreKit 2 transaction when RevenueCat exposes one.
    case completed(StoreKit.Transaction?)
    case cancelled
}

protocol RevenueCatAdapter: Sendable {
    /// `false` until `Purchases.configure(...)` runs. Everything else touches
    /// `Purchases.shared`, which traps before that — check this first.
    var isConfigured: Bool { get }
    /// `true` when the app finishes transactions itself
    /// (`purchasesAreCompletedBy: .myApp`).
    var appCompletesPurchases: Bool { get }
    var frameworkVersion: String { get }
    func purchase(productId: String) async throws -> RevenueCatPurchaseOutcome
    func recordPurchase(_ result: Product.PurchaseResult) async throws
    func syncPurchases() async throws
    func latestTransaction(for productId: String) async -> StoreKit.Transaction?
    /// RevenueCat's last-known customer state first, then every change.
    func customerUpdates() -> AsyncStream<RevenueCatCustomer>
}

struct LiveRevenueCatAdapter: RevenueCatAdapter {

    var isConfigured: Bool { Purchases.isConfigured }

    var appCompletesPurchases: Bool { Purchases.shared.purchasesAreCompletedBy == .myApp }

    var frameworkVersion: String { Purchases.frameworkVersion }

    func purchase(productId: String) async throws -> RevenueCatPurchaseOutcome {
        let products = await Purchases.shared.products([productId])
        guard let product = products.first(where: { $0.productIdentifier == productId }) else {
            throw ErrorCode.productNotAvailableForPurchaseError
        }
        let result = try await Purchases.shared.purchase(product: product)
        if result.userCancelled { return .cancelled }
        return .completed(result.transaction?.sk2Transaction)
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

    func customerUpdates() -> AsyncStream<RevenueCatCustomer> {
        let purchases = Purchases.shared
        return AsyncStream { continuation in
            // `customerInfoStream` registers a fresh observer per stream, so
            // this never competes with the app's own `PurchasesDelegate` or
            // stream consumers.
            let task = Task {
                for await info in purchases.customerInfoStream {
                    continuation.yield(RevenueCatCustomer(
                        appUserID: purchases.appUserID,
                        isAnonymous: purchases.isAnonymous,
                        originalAppUserID: info.originalAppUserId,
                        activeEntitlements: info.entitlements.active.keys.sorted(),
                        purchaseDates: Self.purchaseDates(info)
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func purchaseDates(_ info: CustomerInfo) -> [String: Date] {
        var dates: [String: Date] = [:]
        for productID in info.allPurchasedProductIdentifiers {
            dates[productID] = info.purchaseDate(forProductIdentifier: productID)
        }
        return dates
    }
}
