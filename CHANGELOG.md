# Changelog

All notable changes to GalvaRevenueCat are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows [Semantic Versioning](https://semver.org/).

## [1.0.0] - Unreleased

First release.

### Added

- The `.revenueCat()` integration, passed to `Galva.configure(…, integrations:)`.
- Offer purchases from Galva's in-app messages run through RevenueCat, so entitlements unlock in the same session. Galva-signed promotional offers use Galva's StoreKit purchase, then hand it to RevenueCat with `syncPurchases()` or `recordPurchase(_:)`.
- Galva's subscriber follows RevenueCat's app user ID with `identity: .followRevenueCat`, the default. With `.manual`, your app identifies Galva itself.
- RevenueCat's app user ID and active entitlements are sent to Galva as `$gv_rc_*` attributes.
- Works whichever SDK is configured first: until RevenueCat is configured, offer purchases use Galva's StoreKit flow.
- Supports RevenueCat 5.19.0 up to 6.0.0, from `purchases-ios-spm`.

[1.0.0]: https://github.com/Galva-io/galva-ios-revenuecat/releases/tag/v1.0.0
