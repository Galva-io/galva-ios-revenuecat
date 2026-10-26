//
//  GalvaAdapter.swift
//  GalvaRevenueCat
//
//  The Galva calls the customer sync and purchase controller make, and the
//  Galva user the sync reads, behind a protocol so tests can record and set
//  them. Galva's public API is thread-safe and fire-and-forget, so the live
//  adapter isn't tied to any actor.
//

import Foundation
import Galva

protocol GalvaAdapter: Sendable {
    /// Galva's current user. Accurate from when the sync connects: Galva
    /// installs the integration once `configure` has loaded the persisted
    /// identity.
    var identity: GalvaIdentity { get }
    func identify(userId: String, appAccountToken: UUID?)
    func logOut()
    func setTraits(_ traits: RevenueCatTraits)
    func reconcileTransactions()
}

struct LiveGalvaAdapter: GalvaAdapter {

    var identity: GalvaIdentity {
        GalvaIdentity(userId: AppUser.identifiedUserId, appAccountToken: AppUser.appAccountToken)
    }

    func identify(userId: String, appAccountToken: UUID?) {
        AppUser.identify(userId: userId, appAccountToken: appAccountToken)
    }

    func logOut() {
        AppUser.logOut()
    }

    func setTraits(_ traits: RevenueCatTraits) {
        AppUser.set(traits.galvaTraits)
    }

    func reconcileTransactions() {
        Galva.reconcileTransactions()
    }
}
