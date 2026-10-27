//
//  CustomerSync.swift
//  GalvaRevenueCat
//
//  Applies RevenueCat's state to Galva, off the main thread.
//
//  Waits until RevenueCat is configured — checking right away, then on each
//  app signal — so `Purchases.configure` may run before or after
//  `Galva.configure`. Then it matches Galva to RevenueCat's current user and
//  the customer info RevenueCat has cached for them straight away, without
//  waiting for RevenueCat to send an update, which it may not do for a while
//  (offline, it has no `CustomerInfo` for a new user).
//
//  After that, it looks at RevenueCat again on:
//  • each update RevenueCat sends, when the customer's data changes. One
//    that arrives after RevenueCat's user changed is stale, and replaced by
//    a fresh read;
//  • each app activation: a fresh read of RevenueCat's user and cached
//    customer info;
//  • every two seconds while the app is active: RevenueCat's app user ID,
//    then a fresh read if it changed. RevenueCat sends no update when only
//    the app user ID changes, as when `logIn` merges an anonymous user into
//    a new ID, the usual sign-up.
//  They're handled one at a time, in order, on this actor; `SyncState`
//  decides what each means for Galva, given Galva's current user. The
//  RevenueCat user the sync last mirrored into Galva is persisted, so the
//  next launch can tell a logout it missed.
//

import Foundation
@_spi(GalvaIntegration) import Galva

actor CustomerSync {

    private var state: SyncState
    private let galva: any GalvaAdapter
    private let store: any MirroredUserStore
    private let logger: any GalvaLogger

    init(
        followsRevenueCatIdentity: Bool,
        galva: any GalvaAdapter,
        store: any MirroredUserStore,
        logger: any GalvaLogger
    ) {
        self.state = SyncState(
            followsRevenueCatIdentity: followsRevenueCatIdentity,
            lastMirroredUserID: store.load()
        )
        self.galva = galva
        self.store = store
        self.logger = logger
    }

    /// Wait for RevenueCat, then follow it for the life of the app: until
    /// RevenueCat's updates or `app`'s signals end, which in an app they
    /// don't. Stops `app` when it returns.
    func run(revenueCat: any RevenueCatAdapter, app: AppSignals) async {
        defer { app.stop() }
        guard await waitForConfiguration(of: revenueCat, signals: app.signals) else { return }

        logger.info(.integration, "connected to RevenueCat", metadata: [
            "revenueCatVersion": revenueCat.frameworkVersion,
            "purchasesCompletedBy": revenueCat.appCompletesPurchases ? "myApp" : "revenueCat",
            "identity": state.followsRevenueCatIdentity ? "followRevenueCat" : "manual",
        ])
        let snapshot = revenueCat.snapshot()
        carryOut { $0.connect(to: snapshot, galva: galva.identity) }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await customer in revenueCat.customerUpdates() {
                    await self.apply(customer, revenueCat: revenueCat)
                }
            }
            group.addTask {
                for await signal in app.signals {
                    await self.handle(signal, revenueCat: revenueCat)
                }
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Private

    private func apply(_ customer: RevenueCatCustomer, revenueCat: any RevenueCatAdapter) {
        // Sent for a user RevenueCat no longer has: following it would undo
        // a fresh read that already followed the new one.
        guard customer.appUserID == revenueCat.currentAppUserID else {
            refresh(from: revenueCat)
            return
        }
        carryOut { $0.apply(customer, galva: galva.identity) }
    }

    private func handle(_ signal: AppSignals.Signal, revenueCat: any RevenueCatAdapter) {
        switch signal {
        case .activated:
            refresh(from: revenueCat)
        case .tick:
            // RevenueCat keeps its app user ID in memory; the rest is worth
            // reading only when that changed.
            guard revenueCat.currentAppUserID != state.seenAppUserID else { return }
            logger.debug(.integration, "RevenueCat's app user ID changed; reading RevenueCat again")
            refresh(from: revenueCat)
        }
    }

    private func refresh(from revenueCat: any RevenueCatAdapter) {
        let snapshot = revenueCat.snapshot()
        carryOut { $0.refresh(snapshot, galva: galva.identity) }
    }

    /// Make the Galva calls `decide` returns, then persist the mirrored user
    /// if it changed.
    private func carryOut(_ decide: (inout SyncState) -> [SyncAction]) {
        let mirrored = state.mirroredUserID
        for action in decide(&state) {
            perform(action)
        }
        if state.mirroredUserID != mirrored {
            store.save(state.mirroredUserID)
        }
    }

    private func waitForConfiguration(
        of revenueCat: any RevenueCatAdapter,
        signals: AsyncStream<AppSignals.Signal>
    ) async -> Bool {
        if revenueCat.isConfigured { return true }
        logger.notice(.integration, "RevenueCat isn't configured yet; will connect once it is. Call Purchases.configure(...) at launch.")
        for await _ in signals where revenueCat.isConfigured {
            return true
        }
        return false
    }

    private func perform(_ action: SyncAction) {
        switch action {
        case .identify(let userId):
            logger.info(.integration, "identifying Galva user from RevenueCat", metadata: [
                "userId": userId,
            ])
            galva.identify(userId: userId)
        case .logOut:
            logger.info(.integration, "RevenueCat user changed; logging Galva out")
            galva.logOut()
        case .setTraits(let traits):
            logger.debug(.integration, "updating RevenueCat traits", metadata: [
                "activeEntitlements": traits.activeEntitlements.joined(separator: ","),
            ])
            galva.setTraits(traits)
        case .reconcileTransactions:
            logger.debug(.integration, "RevenueCat purchases changed; reconciling transactions")
            galva.reconcileTransactions()
        }
    }
}
