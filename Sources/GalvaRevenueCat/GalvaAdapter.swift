//
//  GalvaAdapter.swift
//  GalvaRevenueCat
//
//  The Galva calls the customer sync and purchase controller make, behind a
//  protocol so tests can record them. Galva's public API is thread-safe and
//  fire-and-forget, so the live adapter isn't tied to any actor.
//

import Foundation
import Galva

protocol GalvaAdapter: Sendable {
    func identify(userId: String, appAccountToken: UUID?)
    func logOut()
    func setTraits(_ traits: RevenueCatTraits)
    func reconcileTransactions()
}

struct LiveGalvaAdapter: GalvaAdapter {

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
