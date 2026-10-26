//
//  CustomerSync.swift
//  GalvaRevenueCat
//
//  Applies RevenueCat customer updates to Galva, off the main thread.
//
//  Waits until RevenueCat is configured — checking right away, then on each
//  app foreground — so `Purchases.configure` may run before or after
//  `Galva.configure`. Then it matches Galva to RevenueCat's current user
//  straight away, without waiting for RevenueCat to emit, which it may not
//  do for a while (offline, it has no `CustomerInfo` for a new user). After
//  that, updates are handled one at a time, in order, on this actor;
//  `SyncState` decides what each one means for Galva, given Galva's current
//  user. The RevenueCat user the sync last mirrored into Galva is persisted,
//  so the next launch can tell a logout it missed.
//

import Foundation
import Galva

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

    /// Wait for RevenueCat, then apply its updates for the life of the app.
    /// Returns early only if `foregrounds` ends before RevenueCat is
    /// configured.
    func run(revenueCat: any RevenueCatAdapter, foregrounds: ForegroundSignals) async {
        let configured = await waitForConfiguration(of: revenueCat, foregrounds: foregrounds.events)
        foregrounds.stop()
        guard configured else { return }

        logger.info(.integration, "connected to RevenueCat", metadata: [
            "revenueCatVersion": revenueCat.frameworkVersion,
            "purchasesCompletedBy": revenueCat.appCompletesPurchases ? "myApp" : "revenueCat",
            "identity": state.followsRevenueCatIdentity ? "followRevenueCat" : "manual",
        ])
        let user = revenueCat.currentUser
        carryOut { $0.connect(to: user, galva: galva.identity) }
        for await customer in revenueCat.customerUpdates() {
            carryOut { $0.apply(customer, galva: galva.identity) }
        }
    }

    // MARK: - Private

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
        foregrounds: AsyncStream<Void>
    ) async -> Bool {
        if revenueCat.isConfigured { return true }
        logger.notice(.integration, "RevenueCat isn't configured yet; will connect on a later app foreground. Call Purchases.configure(...) at launch.")
        for await _ in foregrounds where revenueCat.isConfigured {
            return true
        }
        return false
    }

    private func perform(_ action: SyncAction) {
        switch action {
        case .identify(let userId, let appAccountToken):
            logger.info(.integration, "identifying Galva user from RevenueCat", metadata: [
                "userId": userId,
                "appAccountToken": appAccountToken == nil ? "unchanged" : "appUserID",
            ])
            galva.identify(userId: userId, appAccountToken: appAccountToken)
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
