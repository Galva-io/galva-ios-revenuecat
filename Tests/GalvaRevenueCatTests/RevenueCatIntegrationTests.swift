//
//  RevenueCatIntegrationTests.swift
//  GalvaRevenueCatTests
//
//  The public `.revenueCat()` factory and its install wiring, end to end
//  against the fakes.
//

import Foundation
import Galva
@testable import GalvaRevenueCat
import XCTest

final class RevenueCatIntegrationTests: XCTestCase {

    func test_factory_identifiesTheIntegration() {
        let integration = Galva.Integration.revenueCat()

        XCTAssertEqual(integration.name, "revenuecat")
        XCTAssertEqual(integration.version, RevenueCatIntegration.version)
    }

    func test_install_connectsOnceRevenueCatIsConfigured() async {
        let revenueCat = FakeRevenueCat()
        revenueCat.isConfigured = false
        let galva = FakeGalva()
        let foreground = FakeForeground()

        RevenueCatIntegration.install(
            identity: .followRevenueCat,
            logger: RecordingLogger(),
            revenueCat: revenueCat,
            galva: galva,
            store: FakeMirroredUserStore(),
            foregrounds: foreground.signals
        )
        revenueCat.updatesContinuation.yield(.identified("user_42"))

        revenueCat.isConfigured = true
        foreground.becomeActive()

        let identified = await eventually {
            galva.calls.contains(.identify(userId: "user_42", appAccountToken: nil))
        }
        XCTAssertTrue(identified)
    }

    func test_install_manualIdentity_onlySyncsTraits() async {
        let revenueCat = FakeRevenueCat()
        let galva = FakeGalva()

        RevenueCatIntegration.install(
            identity: .manual,
            logger: RecordingLogger(),
            revenueCat: revenueCat,
            galva: galva,
            store: FakeMirroredUserStore(),
            foregrounds: FakeForeground().signals
        )
        revenueCat.updatesContinuation.yield(.identified("user_42", entitlements: ["pro"]))

        let synced = await eventually { !galva.calls.isEmpty }
        XCTAssertTrue(synced)
        XCTAssertEqual(galva.calls, [
            .setTraits(RevenueCatTraits(.identified("user_42", entitlements: ["pro"]))),
        ])
    }
}
