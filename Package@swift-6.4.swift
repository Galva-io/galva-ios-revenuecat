// swift-tools-version: 6.2
//
// The manifest SwiftPM reads with Swift 6.4 and later (Xcode 27), instead of
// Package.swift. It's the same package with RevenueCat's floor raised to
// 5.78.0: earlier releases don't compile with Xcode 27 (RevenueCat #6949),
// so an app pinned to one gets a resolution error naming the required
// version instead of compile errors inside RevenueCat. Keep everything else
// identical to Package.swift; CI checks it.
//
// GalvaRevenueCat runs the purchases Galva in-app messages request through
// RevenueCat and keeps Galva's identity in step with RevenueCat's app user ID.
//
// It lives outside galva-ios on purpose: SwiftPM fetches and pins every
// dependency a package declares, even ones only used by products an app never
// links. Keeping RevenueCat here means apps that don't use it never see it.
import PackageDescription

let package = Package(
    name: "GalvaRevenueCat",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "GalvaRevenueCat",
            targets: ["GalvaRevenueCat"]
        ),
    ],
    dependencies: [
        // Local sibling checkout while galva-ios's purchase-controller seam is
        // unreleased. Swap for the tagged release before publishing:
        //     .package(url: "https://github.com/Galva-io/galva-ios", from: "1.0.0"),
        .package(path: "../galva-ios"),
        // RevenueCat's recommended SwiftPM URL. Apps must add RevenueCat with
        // this same URL — an app on `purchases-ios` would end up with two
        // packages declaring a `RevenueCat` module.
        //
        // Floor: the APIs this package uses exist since 5.0.0, but releases
        // before 5.19.0 don't compile with Swift 6.1+ (RevenueCat #4840), and
        // Galva itself needs Xcode 26 — so 5.19.0 is the oldest RevenueCat any
        // Galva app can build. CI proves it on Xcode 26. RevenueCat before
        // 5.78.0 doesn't compile with Xcode 27 (#6949), hence this manifest's
        // floor; Package.swift keeps 5.19.0 for Xcode 26.
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", "5.78.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "GalvaRevenueCat",
            dependencies: [
                .product(name: "Galva", package: "galva-ios"),
                .product(name: "RevenueCat", package: "purchases-ios-spm"),
            ],
            // Declares this package's one required-reason API (UserDefaults,
            // CA92.1: it remembers the RevenueCat user it last mirrored into
            // Galva), so apps don't have to. It collects nothing itself; what
            // reaches Galva's servers is declared in Galva's own manifest.
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "GalvaRevenueCatTests",
            dependencies: [
                "GalvaRevenueCat",
                .product(name: "Galva", package: "galva-ios"),
                .product(name: "RevenueCat", package: "purchases-ios-spm"),
            ]
        ),
    ]
)
