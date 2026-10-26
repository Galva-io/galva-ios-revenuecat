//
//  MirroredUserStore.swift
//  GalvaRevenueCat
//
//  Where `CustomerSync` keeps, across launches, the RevenueCat app user ID it
//  last mirrored into Galva. Behind a protocol so tests keep it in memory.
//

import Foundation

protocol MirroredUserStore: Sendable {
    func load() -> String?
    /// `nil` clears it: the sync mirrors nobody.
    func save(_ appUserID: String?)
}

/// `UserDefaults.standard`, next to Galva's own `co.galva.*` keys. Declared
/// in this package's privacy manifest (required reason CA92.1).
struct LiveMirroredUserStore: MirroredUserStore {

    static let key = "co.galva.revenuecat.mirroredAppUserId"

    func load() -> String? {
        UserDefaults.standard.string(forKey: Self.key)
    }

    func save(_ appUserID: String?) {
        if let appUserID {
            UserDefaults.standard.set(appUserID, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
