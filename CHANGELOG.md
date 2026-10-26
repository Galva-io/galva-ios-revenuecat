# Changelog

All notable changes to GalvaRevenueCat are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the package follows [Semantic Versioning](https://semver.org/).

## [1.0.0] - Unreleased

First release.

### Added

- The `.revenueCat()` integration, passed to `Galva.configure(…, integrations:)`.
- Offer purchases from Galva's in-app messages run through RevenueCat, so entitlements unlock in the same session. Galva-signed promotional offers use Galva's StoreKit purchase, then hand it to RevenueCat with `syncPurchases()` or `recordPurchase(_:)`. After every completed purchase, `Galva.reconcileTransactions()` matches the transaction to the subscriber, since RevenueCat attaches an app account token only to UUID app user IDs.
- If RevenueCat throws after StoreKit has charged the subscriber, because only its receipt post failed, the message reports the purchase as completed instead of an error, and the integration calls `syncPurchases()` so RevenueCat records it.
- If RevenueCat can't load a product, StoreKit is asked why, so the message reports a network error as one instead of an unavailable product.
- Galva's subscriber follows RevenueCat's app user ID with `identity: .followRevenueCat`, the default, across launches too: a `Purchases.logOut` the integration missed logs Galva out at the next launch, even offline, and RevenueCat starting as another user logs Galva out before identifying them. The integration stores the RevenueCat app user ID it last passed to Galva in `UserDefaults`. With `.manual`, your app identifies Galva itself.
- RevenueCat's app user ID and active entitlements are sent to Galva as `$gv_rc_*` attributes, and sent again with the next RevenueCat update after the Galva subscriber changes.
- A privacy manifest declaring the package's `UserDefaults` use (reason CA92.1).
- Works whichever SDK is configured first: until RevenueCat is configured, offer purchases use Galva's StoreKit flow.
- Supports RevenueCat 5.19.0 up to 6.0.0, from `purchases-ios-spm`.

[1.0.0]: https://github.com/Galva-io/galva-ios-revenuecat/releases/tag/v1.0.0
