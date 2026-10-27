//
//  RevenueCatIntegration.swift
//  GalvaRevenueCat
//
//  The public surface: the `.revenueCat()` integration.
//
//      import Galva
//      import GalvaRevenueCat
//      import RevenueCat
//
//      Purchases.configure(withAPIKey: "appl_xxxxxxxx")
//      Galva.configure(apiKey: "pk_live_xxxxxxxx", integrations: [.revenueCat()])
//
//  Galva installs it once it's configured. From then on:
//  • purchases started inside Galva in-app messages run through RevenueCat
//    (`RevenueCatPurchaseController`), so entitlements unlock in-session;
//  • RevenueCat's identity and subscription state are mirrored into Galva
//    off the main thread (`CustomerSync`).
//
//  `Purchases.configure` may run before or after `Galva.configure`. Until
//  RevenueCat is configured, purchases use Galva's built-in StoreKit flow and
//  the sync waits, re-checking each time the app becomes active and every
//  two seconds while it is.
//

import Foundation
@_spi(GalvaIntegration) import Galva

public extension Galva.Integration {

    /// How Galva's user relates to RevenueCat's.
    enum RevenueCatIdentity: Sendable, Hashable {
        /// Galva's user follows RevenueCat's app user ID: `Purchases.logIn`
        /// identifies the Galva user with the same ID and `Purchases.logOut`
        /// logs Galva out. You don't call `AppUser.identify` or `logOut`.
        case followRevenueCat
        /// You identify the Galva user yourself, e.g. when Galva uses a
        /// different user ID than RevenueCat. Purchases and traits still sync.
        case manual
    }

    /// Connect Galva to RevenueCat. Pass it to
    /// `Galva.configure(apiKey:…, integrations:)`.
    ///
    /// - Parameter identity: Whether Galva's user follows RevenueCat's app
    ///   user ID. Default: `.followRevenueCat`.
    static func revenueCat(identity: RevenueCatIdentity = .followRevenueCat) -> Galva.Integration {
        Galva.Integration(
            name: RevenueCatIntegration.name,
            version: RevenueCatIntegration.version
        ) { context in
            RevenueCatIntegration.install(
                identity: identity,
                logger: context.logger,
                revenueCat: LiveRevenueCatAdapter(),
                galva: LiveGalvaAdapter(),
                store: LiveMirroredUserStore(),
                app: .app()
            )
        }
    }
}

enum RevenueCatIntegration {

    static let name = "revenuecat"

    /// This package's version. Bump on every release.
    static let version = "1.0.0"

    /// Install the purchase controller right away — it falls back to Galva's
    /// StoreKit flow until RevenueCat is configured — and start the sync.
    static func install(
        identity: Galva.Integration.RevenueCatIdentity,
        logger: any GalvaLogger,
        revenueCat: any RevenueCatAdapter,
        galva: any GalvaAdapter,
        store: any MirroredUserStore,
        app: AppSignals
    ) {
        Galva.setPurchaseController(
            RevenueCatPurchaseController(revenueCat: revenueCat, galva: galva, logger: logger)
        )
        let sync = CustomerSync(
            followsRevenueCatIdentity: identity == .followRevenueCat,
            galva: galva,
            store: store,
            logger: logger
        )
        // Runs for the life of the app; the task keeps `sync` alive.
        Task {
            await sync.run(revenueCat: revenueCat, app: app)
        }
    }
}
