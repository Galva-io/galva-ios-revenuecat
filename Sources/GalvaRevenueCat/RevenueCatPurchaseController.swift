//
//  RevenueCatPurchaseController.swift
//  GalvaRevenueCat
//
//  Runs the purchases Galva in-app messages request through RevenueCat, so
//  RevenueCat records the transaction and refreshes `CustomerInfo` in the
//  same session. Without it, Galva buys through StoreKit directly and
//  RevenueCat only learns about the purchase on the next launch (StoreKit
//  doesn't emit `Product.purchase()` transactions on `Transaction.updates`).
//
//  Routing
//  ───────
//  • RevenueCat completes purchases (`.revenueCat`, the default)
//      → `Purchases.purchase(product:)`, or for a promotional offer
//        `purchase(product:promotionalOffer:)`. RevenueCat records and
//        finishes it. Its public API can't take Galva's JWS signature, so
//        RevenueCat signs the same App Store offer itself
//        (`promotionalOffer(forProductDiscount:product:)`), with the In-App
//        Purchase key it also needs for StoreKit 2 purchases. Without the
//        key, or a subscription to the product's group on the device, it
//        throws before buying.
//        RevenueCat also throws when StoreKit charged the user and only its
//        own receipt post failed. Offline or on a server error (5xx) it leaves
//        the transaction unfinished and posts it again on the next launch;
//        when its server rejects the receipt (4xx) it finishes it and never
//        posts it again. So when it throws, a verified transaction StoreKit
//        didn't have before means the purchase completed, and a background
//        `syncPurchases()` asks RevenueCat to record it. A consumable
//        RevenueCat finished leaves StoreKit's history, so after a 4xx its
//        purchase can't be told from a failure. When RevenueCat finds no
//        product (it swallows the lookup's error), StoreKit is asked
//        directly whether the network failed or the App Store doesn't sell
//        it.
//  • The app completes purchases (`.myApp`)
//      → Galva's StoreKit flow, with Galva's signature for a promotional
//        offer, then `recordPurchase(_:)` (`syncPurchases()`
//        when RevenueCat runs StoreKit 1). The app still finishes the
//        transaction, exactly as for purchases it starts itself.
//  • RevenueCat not configured yet
//      → Galva's StoreKit flow, transaction left unfinished for RevenueCat
//        to pick up once it starts.
//
//  Only the routing decision runs on the main actor (the protocol
//  requirement); RevenueCat and StoreKit do their work off it. Every
//  completed purchase triggers `Galva.reconcileTransactions()`, so Galva maps
//  the new `originalTransactionId` to the user right away.
//

import Foundation
@_spi(GalvaIntegration) import Galva
import RevenueCat
import StoreKit

struct RevenueCatPurchaseController: GalvaPurchaseController {

    let revenueCat: any RevenueCatAdapter
    let galva: any GalvaAdapter
    let logger: any GalvaLogger

    @MainActor
    func purchase(_ request: Galva.PurchaseRequest) async throws -> Galva.PurchaseResult {
        let result: Galva.PurchaseResult
        if !revenueCat.isConfigured {
            logger.warning(.integration, "RevenueCat isn't configured; buying with Galva's built-in StoreKit flow", metadata: [
                "productId": request.productId,
            ])
            result = try await purchaseWithStoreKit(request, handOff: .leaveForRevenueCat)
        } else if revenueCat.appCompletesPurchases {
            result = try await purchaseWithStoreKit(request, handOff: .recordPurchase)
        } else {
            result = try await purchaseWithRevenueCat(
                productId: request.productId,
                promotionalOfferID: request.promotionalOffer?.offerId
            )
        }
        if case .completed = result {
            galva.reconcileTransactions()
        }
        return result
    }

    // MARK: - RevenueCat path

    @MainActor
    private func purchaseWithRevenueCat(
        productId: String,
        promotionalOfferID: String?
    ) async throws -> Galva.PurchaseResult {
        // Noted first, so a transaction StoreKit makes before RevenueCat
        // throws stands out.
        let before = await revenueCat.latestTransactionID(for: productId)
        let outcome: RevenueCatPurchaseOutcome
        do {
            outcome = try await revenueCat.purchase(productId: productId, promotionalOfferID: promotionalOfferID)
        } catch {
            if (error as? ErrorCode) == .invalidAppleSubscriptionKeyError {
                logger.error(.integration, "RevenueCat can't sign the promotional offer: its project has no valid In-App Purchase key for this app. Upload one in RevenueCat; StoreKit 2 purchases need it too.", metadata: [
                    "productId": productId,
                ])
            }
            return try await result(for: error, productId: productId, latestTransactionBefore: before)
        }
        switch outcome {
        case .cancelled:
            return .cancelled
        case .productNotFound:
            throw await productLookupFailure(productId: productId)
        case .offerNotFound:
            throw Galva.PurchaseError.invalidOffer(
                "The App Store product \(productId) has no promotional offer \(promotionalOfferID ?? "")"
            )
        case .completed(let transaction?):
            return .completed(transaction)
        case .completed(nil):
            // RevenueCat in StoreKit 1 mode hands back an SK1 transaction;
            // StoreKit 2 still sees the same purchase.
            return try await completedInStoreKit(productId: productId)
        }
    }

    /// The outcome of a RevenueCat purchase that threw. Unless it was
    /// cancelled or is pending, check whether StoreKit charged the user
    /// anyway: if so, the message shows the purchase as completed rather than
    /// an error that invites paying twice.
    @MainActor
    private func result(
        for error: any Error,
        productId: String,
        latestTransactionBefore before: UInt64?
    ) async throws -> Galva.PurchaseResult {
        let mapped = Result { try Self.result(for: error) }
        if case .success(let result) = mapped {
            return result
        }
        // Compares ids, not dates, so the device clock can't fool it.
        guard let latest = await revenueCat.latestTransactionID(for: productId), latest != before else {
            return try mapped.get()
        }
        logger.warning(.integration, "RevenueCat failed after StoreKit completed the purchase; syncing purchases so RevenueCat records it", metadata: [
            "productId": productId,
            "transactionId": String(latest),
        ], error: error)
        // Best-effort, and slow on the bad network that often caused this,
        // so the message doesn't wait for it.
        Task {
            await sync(ifItFails: "RevenueCat records the purchase on the next launch if it left the transaction unfinished, otherwise on its next sync or restore")
        }
        return try await completedInStoreKit(productId: productId)
    }

    /// A purchase StoreKit completed, with its verified transaction.
    @MainActor
    private func completedInStoreKit(productId: String) async throws -> Galva.PurchaseResult {
        if let transaction = await revenueCat.latestTransaction(for: productId) {
            return .completed(transaction)
        }
        logger.error(.integration, "The purchase completed but StoreKit has no verified transaction for it", metadata: [
            "productId": productId,
        ])
        throw Galva.PurchaseError.failed("The purchase completed but StoreKit returned no transaction")
    }

    /// Why RevenueCat returned no product. It swallows the lookup's error, so
    /// a flaky network looks like a product the App Store doesn't sell; asked
    /// directly, StoreKit tells them apart, as in Galva's own StoreKit flow.
    private func productLookupFailure(productId: String) async -> Galva.PurchaseError {
        do {
            guard try await revenueCat.storeKitHasProduct(productId) else {
                return .productUnavailable
            }
            return .failed("RevenueCat couldn't load product \(productId), though the App Store sells it")
        } catch StoreKitError.networkError(let underlying) {
            return .networkError(String(describing: underlying))
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Map an error thrown by RevenueCat's purchase API onto the outcome the
    /// in-app message understands: cancellation and Ask to Buy are normal
    /// outcomes, everything else becomes a `Galva.PurchaseError`.
    static func result(for error: any Error) throws -> Galva.PurchaseResult {
        guard let code = error as? ErrorCode else {
            throw Galva.PurchaseError.failed(String(describing: error))
        }
        let detail = (error as NSError).localizedDescription
        switch code {
        case .purchaseCancelledError:
            return .cancelled
        case .paymentPendingError:
            return .pending
        case .productNotAvailableForPurchaseError:
            throw Galva.PurchaseError.productUnavailable
        case .purchaseNotAllowedError:
            throw Galva.PurchaseError.purchaseNotAllowed
        case .ineligibleError:
            throw Galva.PurchaseError.ineligibleForOffer
        case .invalidPromotionalOfferError, .invalidAppleSubscriptionKeyError:
            throw Galva.PurchaseError.invalidOffer(detail)
        case .networkError, .offlineConnectionError:
            throw Galva.PurchaseError.networkError(detail)
        default:
            throw Galva.PurchaseError.failed(detail)
        }
    }

    // MARK: - StoreKit path + hand-off

    /// How RevenueCat learns about a purchase made with Galva's StoreKit flow.
    private enum HandOff {
        /// RevenueCat isn't configured; it picks up the unfinished
        /// transaction once it starts.
        case leaveForRevenueCat
        /// `.myApp` mode: record it; the app finishes it.
        case recordPurchase
    }

    @MainActor
    private func purchaseWithStoreKit(
        _ request: Galva.PurchaseRequest,
        handOff: HandOff
    ) async throws -> Galva.PurchaseResult {
        let result = try await request.purchaseWithStoreKit()
        switch result {
        case .success(.verified(let transaction)):
            // The user has paid: a failed hand-off is logged, never surfaced
            // as a purchase failure.
            switch handOff {
            case .leaveForRevenueCat:
                break
            case .recordPurchase:
                await record(result)
            }
            return .completed(transaction)
        case .success(.unverified(_, let error)):
            throw Galva.PurchaseError.verificationFailed(String(describing: error))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw Galva.PurchaseError.failed("Unknown StoreKit purchase result")
        }
    }

    private func record(_ result: Product.PurchaseResult) async {
        do {
            try await revenueCat.recordPurchase(result)
        } catch let error as ErrorCode where error == .configurationError {
            // `recordPurchase` requires StoreKit 2; under StoreKit 1 a sync
            // posts the receipt instead.
            await sync(ifItFails: "RevenueCat picks the transaction up on next launch")
        } catch {
            logger.warning(.integration, "RevenueCat recordPurchase failed", error: error)
        }
    }

    /// `syncPurchases()`, best-effort: `false` when it failed, after
    /// logging what happens to the purchase instead.
    @discardableResult
    private func sync(ifItFails consequence: String) async -> Bool {
        do {
            try await revenueCat.syncPurchases()
            return true
        } catch {
            logger.warning(.integration, "RevenueCat syncPurchases failed; \(consequence)", error: error)
            return false
        }
    }
}
