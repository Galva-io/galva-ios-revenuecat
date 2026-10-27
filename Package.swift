// swift-tools-version: 6.2
//
// GalvaRevenueCat runs the purchases Galva in-app messages request through
// RevenueCat and keeps Galva's identity in step with RevenueCat's app user ID.
//
// It lives outside galva-ios on purpose: SwiftPM fetches and pins every
// dependency a package declares, even ones only used by products an app never
// links. Keeping RevenueCat here means apps that don't use it never see it.
//
// Tools version 6.2 is Xcode 26, the oldest Xcode Galva compiles with, so
// SwiftPM turns older toolchains away at resolution. Swift 6.4 and later
// (Xcode 27) read Package@swift-6.4.swift instead, which differs only in
// RevenueCat's floor; CI checks that the two stay in step.
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
        // 5.78.0 doesn't compile with Xcode 27 (#6949), so
        // Package@swift-6.4.swift, which Xcode 27 reads instead of this file,
        // raises the floor to 5.78.0.
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", "5.19.0"..<"6.0.0"),
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
