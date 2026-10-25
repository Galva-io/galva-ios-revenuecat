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
//  • RevenueCat completes purchases (`.revenueCat`, the default), no offer
//      → `Purchases.purchase(product:)`. RevenueCat records and finishes it.
//  • RevenueCat completes purchases, Galva-signed promotional offer
//      → Galva's StoreKit flow (RevenueCat's public API can't apply a
//        Galva-signed JWS offer), then `syncPurchases()` so RevenueCat
//        ingests it, then `finish()`. If the sync fails the transaction is
//        left unfinished; RevenueCat records and finishes it from
//        `Transaction.updates` on the next launch.
//  • The app completes purchases (`.myApp`)
//      → Galva's StoreKit flow, then `recordPurchase(_:)` (`syncPurchases()`
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
import Galva
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
        } else if request.promotionalOffer != nil {
            result = try await purchaseWithStoreKit(request, handOff: .syncThenFinish)
        } else {
            result = try await purchaseWithRevenueCat(productId: request.productId)
        }
        if case .completed = result {
            galva.reconcileTransactions()
        }
        return result
    }

    // MARK: - RevenueCat path

    @MainActor
    private func purchaseWithRevenueCat(productId: String) async throws -> Galva.PurchaseResult {
        let outcome: RevenueCatPurchaseOutcome
        do {
            outcome = try await revenueCat.purchase(productId: productId)
        } catch {
            return try Self.result(for: error)
        }
        switch outcome {
        case .cancelled:
            return .cancelled
        case .completed(let transaction?):
            return .completed(transaction)
        case .completed(nil):
            // RevenueCat in StoreKit 1 mode hands back an SK1 transaction;
            // StoreKit 2 still sees the same purchase.
            if let transaction = await revenueCat.latestTransaction(for: productId) {
                return .completed(transaction)
            }
            logger.error(.integration, "RevenueCat completed a purchase but StoreKit has no verified transaction for it", metadata: [
                "productId": productId,
            ])
            throw Galva.PurchaseError.failed("RevenueCat completed the purchase but StoreKit returned no transaction")
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
        case .invalidPromotionalOfferError:
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
        /// `.revenueCat` mode: sync it, then finish it.
        case syncThenFinish
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
            case .syncThenFinish:
                if await sync() {
                    await transaction.finish()
                }
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
            await sync()
        } catch {
            logger.warning(.integration, "RevenueCat recordPurchase failed", error: error)
        }
    }

    @discardableResult
    private func sync() async -> Bool {
        do {
            try await revenueCat.syncPurchases()
            return true
        } catch {
            logger.warning(.integration, "RevenueCat syncPurchases failed; RevenueCat picks the transaction up on next launch", error: error)
            return false
        }
    }
}
