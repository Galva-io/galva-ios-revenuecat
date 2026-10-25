//
//  RevenueCatPurchaseControllerTests.swift
//  GalvaRevenueCatTests
//
//  Pins purchase routing (RevenueCat API vs Galva's StoreKit flow + hand-off)
//  and the RevenueCat error → Galva outcome mapping. A verified StoreKit
//  transaction can't be constructed in unit tests, so the post-purchase
//  hand-off (`recordPurchase` / `syncPurchases` + `finish`) is covered by
//  sandbox QA instead.
//

import Foundation
@_spi(Testing) import Galva
@testable import GalvaRevenueCat
import RevenueCat
import StoreKit
import XCTest

@MainActor
final class RevenueCatPurchaseControllerTests: XCTestCase {

    private var revenueCat: FakeRevenueCat!
    private var galva: FakeGalva!
    private var logger: RecordingLogger!
    private var storeKitCalls = 0

    override func setUp() async throws {
        revenueCat = FakeRevenueCat()
        galva = FakeGalva()
        logger = RecordingLogger()
        storeKitCalls = 0
    }

    private func purchase(
        promotionalOffer: Galva.PromotionalOffer? = nil,
        storeKitResult: Product.PurchaseResult = .userCancelled
    ) async throws -> Galva.PurchaseResult {
        let controller = RevenueCatPurchaseController(revenueCat: revenueCat, galva: galva, logger: logger)
        let request = Galva.PurchaseRequest(
            productId: "com.app.pro.year",
            promotionalOffer: promotionalOffer,
            appAccountToken: UUID(),
            messageId: "msg-1",
            storeKitPurchase: {
                self.storeKitCalls += 1
                return storeKitResult
            }
        )
        return try await controller.purchase(request)
    }

    private let offer = Galva.PromotionalOffer(offerId: "winback_50", compactJWS: "h.p.s")

    // MARK: - Routing

    func test_revenueCatMode_plainOffer_buysThroughRevenueCat() async throws {
        revenueCat.purchaseResult = .success(.cancelled)

        let result = try await purchase()

        XCTAssertEqual(revenueCat.purchasedProductIds, ["com.app.pro.year"])
        XCTAssertEqual(storeKitCalls, 0)
        guard case .cancelled = result else { return XCTFail("expected .cancelled, got \(result)") }
    }

    func test_revenueCatMode_promotionalOffer_usesGalvaStoreKitFlow() async throws {
        // RevenueCat's public API can't apply a Galva-signed JWS offer.
        let result = try await purchase(promotionalOffer: offer)

        XCTAssertEqual(storeKitCalls, 1)
        XCTAssertEqual(revenueCat.purchasedProductIds, [])
        XCTAssertEqual(revenueCat.syncCount, 0, "nothing to sync for a cancelled purchase")
        guard case .cancelled = result else { return XCTFail("expected .cancelled, got \(result)") }
    }

    func test_myAppMode_usesGalvaStoreKitFlow() async throws {
        revenueCat.appCompletesPurchases = true

        let result = try await purchase(storeKitResult: .pending)

        XCTAssertEqual(storeKitCalls, 1)
        XCTAssertEqual(revenueCat.purchasedProductIds, [])
        XCTAssertEqual(revenueCat.recordCount, 0, "pending purchases are recorded once they complete")
        guard case .pending = result else { return XCTFail("expected .pending, got \(result)") }
    }

    func test_revenueCatNotConfigured_fallsBackToGalvaStoreKitFlow() async throws {
        revenueCat.isConfigured = false

        let result = try await purchase()

        XCTAssertEqual(storeKitCalls, 1)
        XCTAssertEqual(revenueCat.purchasedProductIds, [], "Purchases.shared would trap before configure")
        XCTAssertTrue(logger.messages.contains { $0.contains("isn't configured") })
        guard case .cancelled = result else { return XCTFail("expected .cancelled, got \(result)") }
    }

    func test_cancelledPurchase_doesNotReconcile() async throws {
        _ = try await purchase()

        XCTAssertEqual(galva.calls, [])
    }

    func test_revenueCatCompletedWithoutTransaction_andNoneInStoreKit_fails() async {
        revenueCat.purchaseResult = .success(.completed(nil))
        revenueCat.latest = nil

        do {
            _ = try await purchase()
            XCTFail("expected a failure")
        } catch let error as Galva.PurchaseError {
            guard case .failed = error else { return XCTFail("expected .failed, got \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(galva.calls, [], "only completed purchases reconcile")
    }

    func test_revenueCatThrowsCancelled_isACancelledOutcome() async throws {
        revenueCat.purchaseResult = .failure(ErrorCode.purchaseCancelledError)

        guard case .cancelled = try await purchase() else { return XCTFail("expected .cancelled") }
    }

    func test_revenueCatThrowsPending_isAPendingOutcome() async throws {
        revenueCat.purchaseResult = .failure(ErrorCode.paymentPendingError)

        guard case .pending = try await purchase() else { return XCTFail("expected .pending") }
    }

    func test_revenueCatThrowsIneligible_surfacesIneligibleForOffer() async {
        revenueCat.purchaseResult = .failure(ErrorCode.ineligibleError)

        do {
            _ = try await purchase()
            XCTFail("expected a failure")
        } catch let error as Galva.PurchaseError {
            XCTAssertEqual(error, .ineligibleForOffer)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Error mapping

    func test_errorMapping() {
        let throwing: [(ErrorCode, (Galva.PurchaseError) -> Bool)] = [
            (.productNotAvailableForPurchaseError, { $0 == .productUnavailable }),
            (.purchaseNotAllowedError, { $0 == .purchaseNotAllowed }),
            (.ineligibleError, { $0 == .ineligibleForOffer }),
            (.invalidPromotionalOfferError, { if case .invalidOffer = $0 { true } else { false } }),
            (.networkError, { if case .networkError = $0 { true } else { false } }),
            (.offlineConnectionError, { if case .networkError = $0 { true } else { false } }),
            (.storeProblemError, { if case .failed = $0 { true } else { false } }),
            (.receiptAlreadyInUseError, { if case .failed = $0 { true } else { false } }),
        ]
        for (code, matches) in throwing {
            XCTAssertThrowsError(try RevenueCatPurchaseController.result(for: code), "\(code)") { error in
                guard let error = error as? Galva.PurchaseError else {
                    return XCTFail("\(code): expected Galva.PurchaseError, got \(error)")
                }
                XCTAssertTrue(matches(error), "\(code) → \(error)")
            }
        }
    }

    func test_errorMapping_bridgedNSError() throws {
        // RevenueCat throws its errors as NSErrors in the ErrorCode domain.
        let nsError = ErrorCode.purchaseCancelledError as NSError
        guard case .cancelled = try RevenueCatPurchaseController.result(for: nsError) else {
            return XCTFail("expected .cancelled")
        }
    }

    func test_errorMapping_nonRevenueCatError_isFailed() {
        XCTAssertThrowsError(try RevenueCatPurchaseController.result(for: URLError(.timedOut))) { error in
            guard case .failed? = error as? Galva.PurchaseError else {
                return XCTFail("expected .failed, got \(error)")
            }
        }
    }
}
