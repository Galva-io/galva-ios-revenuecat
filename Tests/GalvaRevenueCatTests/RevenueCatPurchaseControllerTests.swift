//
//  RevenueCatPurchaseControllerTests.swift
//  GalvaRevenueCatTests
//
//  Pins purchase routing (RevenueCat API vs Galva's StoreKit flow + hand-off)
//  and the RevenueCat error → Galva outcome mapping. A verified StoreKit
//  transaction can't be constructed in unit tests — not even with
//  `SKTestSession`, which `swift test` isn't entitled to — so the
//  post-purchase hand-off (`recordPurchase`, or `syncPurchases` under
//  StoreKit 1) is covered by sandbox QA instead. "RevenueCat threw after StoreKit charged"
//  is told by StoreKit's transaction ids, which the fake stands in for, so
//  it's pinned up to the final `.completed`, which needs a real transaction.
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
        XCTAssertEqual(revenueCat.purchasedOfferIDs, [nil])
        XCTAssertEqual(storeKitCalls, 0)
        guard case .cancelled = result else { return XCTFail("expected .cancelled, got \(result)") }
    }

    func test_revenueCatMode_promotionalOffer_buysThroughRevenueCat_withTheOfferID() async throws {
        // RevenueCat signs the App Store offer itself; Galva's JWS isn't used.
        revenueCat.purchaseResult = .success(.cancelled)

        let result = try await purchase(promotionalOffer: offer)

        XCTAssertEqual(revenueCat.purchasedProductIds, ["com.app.pro.year"])
        XCTAssertEqual(revenueCat.purchasedOfferIDs, ["winback_50"])
        XCTAssertEqual(storeKitCalls, 0)
        XCTAssertEqual(revenueCat.syncCount, 0)
        guard case .cancelled = result else { return XCTFail("expected .cancelled, got \(result)") }
    }

    func test_myAppMode_usesGalvaStoreKitFlow_withOrWithoutAnOffer() async throws {
        for promotionalOffer in [nil, offer] {
            revenueCat = FakeRevenueCat()
            revenueCat.appCompletesPurchases = true
            storeKitCalls = 0

            let result = try await purchase(promotionalOffer: promotionalOffer, storeKitResult: .pending)

            let name = promotionalOffer == nil ? "regular offer" : "promotional offer"
            XCTAssertEqual(storeKitCalls, 1, name)
            XCTAssertEqual(revenueCat.purchasedProductIds, [], name)
            XCTAssertEqual(revenueCat.recordCount, 0, "\(name): pending purchases are recorded once they complete")
            guard case .pending = result else { return XCTFail("\(name): expected .pending, got \(result)") }
        }
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

    func test_revenueCatThrowsCancelledOrPending_doesNotLookForATransaction() async throws {
        for code in [ErrorCode.purchaseCancelledError, .paymentPendingError] {
            revenueCat = FakeRevenueCat()
            revenueCat.purchaseResult = .failure(code)

            _ = try await purchase()

            XCTAssertEqual(revenueCat.purchaseCalls, [.latestTransactionID, .purchase], "\(code)")
        }
    }

    // MARK: - RevenueCat throws after StoreKit charged

    /// StoreKit's latest transaction ids for the product: before the
    /// purchase, then after RevenueCat throws.
    private func purchaseThatThrows(
        transactionIDs before: UInt64?,
        _ after: UInt64?
    ) async -> Result<Galva.PurchaseResult, any Error> {
        // `Purchases.purchase(product:)` also throws when only RevenueCat's
        // receipt post failed, after StoreKit charged the user.
        revenueCat.purchaseResult = .failure(ErrorCode.networkError)
        revenueCat.latestTransactionIDs = [before, after]
        do {
            return .success(try await purchase())
        } catch {
            return .failure(error)
        }
    }

    func test_revenueCatThrows_noNewTransactionInStoreKit_fails() async {
        let cases: [(String, UInt64?, UInt64?)] = [
            ("still the one from before", 7, 7),
            ("no transaction at all", nil, nil),
            ("none now, though there was one", 7, nil),
        ]
        for (name, before, after) in cases {
            revenueCat = FakeRevenueCat()
            logger = RecordingLogger()

            let result = await purchaseThatThrows(transactionIDs: before, after)

            guard case .failure(Galva.PurchaseError.networkError) = result else {
                XCTFail("\(name): expected RevenueCat's error, mapped, got \(result)")
                continue
            }
            XCTAssertEqual(
                revenueCat.purchaseCalls,
                [.latestTransactionID, .purchase, .latestTransactionID],
                "\(name): notes StoreKit's latest transaction before buying, and checks again after RevenueCat throws"
            )
            XCTAssertFalse(logger.messages.contains { $0.contains("after StoreKit completed") }, name)
            XCTAssertEqual(revenueCat.syncCount, 0, name)
            XCTAssertEqual(galva.calls, [], "\(name): not completed, nothing to reconcile")
        }
    }

    func test_revenueCatThrows_newTransactionInStoreKit_isAPaidPurchase_andSyncsIt() async throws {
        // The user paid; RevenueCat may already have finished the transaction
        // (its server rejected the receipt), so it wouldn't post it again.
        let cases: [(String, UInt64?, UInt64?)] = [
            ("first purchase of the product", nil, 8),
            ("bought before, a newer one now", 7, 8),
        ]
        for (name, before, after) in cases {
            revenueCat = FakeRevenueCat()
            logger = RecordingLogger()

            _ = await purchaseThatThrows(transactionIDs: before, after)

            let warning = try XCTUnwrap(
                logger.entries.first { $0.message.contains("RevenueCat failed after StoreKit completed the purchase") },
                name
            )
            XCTAssertEqual(warning.metadata["transactionId"], "8", name)
            let fake = revenueCat!
            let synced = await eventually { @Sendable in fake.syncCount == 1 }
            XCTAssertTrue(synced, "\(name): RevenueCat is asked to record it")
            // Then the transaction itself, for `.completed`. A
            // `StoreKit.Transaction` can't be made in tests, so the fake has
            // none to return and the purchase ends there.
            XCTAssertEqual(fake.purchaseCalls, [.latestTransactionID, .purchase, .latestTransactionID, .latestTransaction], name)
        }
    }

    func test_revenueCatThrows_paid_syncFails_isLogged() async {
        revenueCat.syncError = ErrorCode.networkError

        _ = await purchaseThatThrows(transactionIDs: nil, 8)

        let logger = logger!
        let logged = await eventually { @Sendable in logger.messages.contains { $0.contains("syncPurchases failed") } }
        XCTAssertTrue(logged)
        XCTAssertEqual(revenueCat.syncCount, 1)
    }

    // MARK: - RevenueCat returns no product

    private func expectFailure(
        promotionalOffer: Galva.PromotionalOffer? = nil,
        _ matches: (Galva.PurchaseError) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await purchase(promotionalOffer: promotionalOffer)
            XCTFail("\(message): expected a failure, got \(result)", file: file, line: line)
        } catch let error as Galva.PurchaseError {
            XCTAssertTrue(matches(error), "\(message): got \(error)", file: file, line: line)
        } catch {
            XCTFail("\(message): unexpected error \(error)", file: file, line: line)
        }
    }

    func test_productNotFound_storeKitOffline_isANetworkError() async {
        // RevenueCat swallows the lookup error and returns no product.
        revenueCat.purchaseResult = .success(.productNotFound)
        revenueCat.storeKitLookupResult = .failure(StoreKitError.networkError(URLError(.notConnectedToInternet)))

        await expectFailure({ if case .networkError = $0 { true } else { false } }, "offline")
        XCTAssertEqual(revenueCat.purchaseCalls, [.latestTransactionID, .purchase, .storeKitLookup])
    }

    func test_productNotFound_storeKitFails_isFailed() async {
        revenueCat.purchaseResult = .success(.productNotFound)
        revenueCat.storeKitLookupResult = .failure(StoreKitError.unknown)

        await expectFailure({ if case .failed = $0 { true } else { false } }, "StoreKit error")
    }

    func test_productNotFound_storeKitDoesNotKnowIt_isProductUnavailable() async {
        revenueCat.purchaseResult = .success(.productNotFound)
        revenueCat.storeKitLookupResult = .success(false)

        await expectFailure({ $0 == .productUnavailable }, "unknown product")
    }

    func test_productNotFound_storeKitHasIt_isFailed_blamingRevenueCat() async {
        revenueCat.purchaseResult = .success(.productNotFound)
        revenueCat.storeKitLookupResult = .success(true)

        await expectFailure({
            if case .failed(let detail) = $0 { detail.contains("RevenueCat") } else { false }
        }, "RevenueCat-only failure")
    }

    // MARK: - Promotional offers RevenueCat can't apply

    func test_revenueCatThrowsIneligible_surfacesIneligibleForOffer() async {
        // RevenueCat won't sign an offer without a subscription to the
        // product's group on the device.
        revenueCat.purchaseResult = .failure(ErrorCode.ineligibleError)

        await expectFailure(promotionalOffer: offer, { $0 == .ineligibleForOffer }, "ineligible")
        XCTAssertEqual(storeKitCalls, 0)
    }

    func test_offerTheProductDoesNotHave_isAnInvalidOffer() async {
        revenueCat.purchaseResult = .success(.offerNotFound)

        await expectFailure(promotionalOffer: offer, {
            if case .invalidOffer(let detail) = $0 { detail.contains("winback_50") } else { false }
        }, "unknown offer")
        XCTAssertEqual(storeKitCalls, 0, "not bought another way")
    }

    func test_revenueCatCannotSignTheOffer_isAnInvalidOffer_andSaysHowToFixIt() async throws {
        // Its project has no In-App Purchase key for the app.
        revenueCat.purchaseResult = .failure(ErrorCode.invalidAppleSubscriptionKeyError)

        await expectFailure(promotionalOffer: offer, {
            if case .invalidOffer = $0 { true } else { false }
        }, "no In-App Purchase key")

        let entry = try XCTUnwrap(logger.entries.first { $0.message.contains("In-App Purchase key") })
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(storeKitCalls, 0, "not bought another way")
    }

    // MARK: - Error mapping

    func test_errorMapping() {
        let throwing: [(ErrorCode, (Galva.PurchaseError) -> Bool)] = [
            (.productNotAvailableForPurchaseError, { $0 == .productUnavailable }),
            (.purchaseNotAllowedError, { $0 == .purchaseNotAllowed }),
            (.ineligibleError, { $0 == .ineligibleForOffer }),
            (.invalidPromotionalOfferError, { if case .invalidOffer = $0 { true } else { false } }),
            (.invalidAppleSubscriptionKeyError, { if case .invalidOffer = $0 { true } else { false } }),
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
