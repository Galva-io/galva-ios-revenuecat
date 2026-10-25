//
//  CustomerSync.swift
//  GalvaRevenueCat
//
//  Applies RevenueCat customer updates to Galva, off the main thread.
//
//  Waits until RevenueCat is configured — checking right away, then on each
//  app foreground — so `Purchases.configure` may run before or after
//  `Galva.configure`. Updates are handled one at a time, in order, on this
//  actor; `SyncState` decides what each one means for Galva.
//

import Foundation
import Galva

actor CustomerSync {

    private var state: SyncState
    private let galva: any GalvaAdapter
    private let logger: any GalvaLogger

    init(followsRevenueCatIdentity: Bool, galva: any GalvaAdapter, logger: any GalvaLogger) {
        self.state = SyncState(followsRevenueCatIdentity: followsRevenueCatIdentity)
        self.galva = galva
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
        for await customer in revenueCat.customerUpdates() {
            apply(customer)
        }
    }

    func apply(_ customer: RevenueCatCustomer) {
        for action in state.apply(customer) {
            perform(action)
        }
    }

    // MARK: - Private

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
