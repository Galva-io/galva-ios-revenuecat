// swift-tools-version: 6.0
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
        // Galva app can build. CI proves it on Xcode 26. Apps on Xcode 27 need
        // RevenueCat 5.78.0+ (#6949) for RevenueCat itself to compile;
        // SwiftPM's resolution already picks a newer release for them.
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", "5.19.0"..<"6.0.0"),
    ],
    targets: [
        .target(
            name: "GalvaRevenueCat",
            dependencies: [
                .product(name: "Galva", package: "galva-ios"),
                .product(name: "RevenueCat", package: "purchases-ios-spm"),
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
