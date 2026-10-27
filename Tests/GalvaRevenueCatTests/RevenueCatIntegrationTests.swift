//
//  RevenueCatIntegrationTests.swift
//  GalvaRevenueCatTests
//
//  The public `.revenueCat()` factory and its install wiring, end to end
//  against the fakes.
//

import Foundation
@_spi(GalvaIntegration) import Galva
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
        revenueCat.start(as: .identified("user_42"))
        let galva = FakeGalva()
        let app = FakeApp()

        RevenueCatIntegration.install(
            identity: .followRevenueCat,
            logger: RecordingLogger(),
            revenueCat: revenueCat,
            galva: galva,
            store: FakeMirroredUserStore(),
            app: app.signals
        )

        revenueCat.isConfigured = true
        app.becomeActive()

        let identified = await eventually {
            galva.calls.contains(.identify(userId: "user_42"))
        }
        XCTAssertTrue(identified)
    }

    func test_install_manualIdentity_onlySyncsTraits() async {
        let revenueCat = FakeRevenueCat()
        revenueCat.start(as: .identified("user_42", entitlements: ["pro"]))
        let galva = FakeGalva()

        RevenueCatIntegration.install(
            identity: .manual,
            logger: RecordingLogger(),
            revenueCat: revenueCat,
            galva: galva,
            store: FakeMirroredUserStore(),
            app: FakeApp().signals
        )

        let synced = await eventually { !galva.calls.isEmpty }
        XCTAssertTrue(synced)
        XCTAssertEqual(galva.calls, [
            .setTraits(RevenueCatTraits(.identified("user_42", entitlements: ["pro"]))),
        ])
    }
}
