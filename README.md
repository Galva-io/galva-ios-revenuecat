# GalvaRevenueCat

Connect the [Galva iOS SDK](https://github.com/Galva-io/galva-ios) to [RevenueCat](https://www.revenuecat.com) with one line:

```swift
Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat()])
```

- **Offers bought in Galva's messages go through RevenueCat.** RevenueCat records and finishes the transaction, and the subscriber's entitlement unlocks right away. Without this, RevenueCat only sees those purchases on the next launch.
- **Galva follows RevenueCat's identity.** `Purchases.logIn` and `logOut` identify and log out the Galva subscriber too, so you don't call `AppUser.identify` yourself.
- **Both SDKs agree on purchases.** They attach the same StoreKit app account token, and purchases from your own RevenueCat paywall reach Galva right away.

> **Status: pre-release.** `Package.swift` depends on a sibling `../galva-ios` checkout until galva-ios ships the integrations API in a tagged release.

---

## Quick start

These steps assume you've registered your app in Galva and copied its App ID. See the [Galva iOS quick start](https://github.com/Galva-io/galva-ios#quick-start).

### 1. Add the package

In Xcode, choose **File → Add Package Dependencies…**, paste the URL below, pick **Up to Next Major Version**, and add the **GalvaRevenueCat** library to your app target. It brings in Galva and RevenueCat.

```
https://github.com/Galva-io/galva-ios-revenuecat
```

<details>
<summary>Using <code>Package.swift</code> instead</summary>

```swift
dependencies: [
    .package(url: "https://github.com/Galva-io/galva-ios-revenuecat", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "GalvaRevenueCat", package: "galva-ios-revenuecat")]
    ),
]
```

</details>

> [!IMPORTANT]
> Add RevenueCat from **`https://github.com/RevenueCat/purchases-ios-spm`**, RevenueCat's recommended Swift Package Manager URL. If your app uses `purchases-ios`, switch to `purchases-ios-spm`: it's the same SDK at the same versions. Otherwise SwiftPM finds two packages that declare a `RevenueCat` module and stops the build.

### 2. Configure

Configure RevenueCat, then pass `.revenueCat()` to Galva:

```swift
import Galva
import GalvaRevenueCat
import RevenueCat

@main
struct MyApp: App {
    init() {
        Purchases.configure(withAPIKey: "appl_your_key")
        Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat()])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in Galva.handleOpenURL(url) }  // opens Galva links
        }
    }
}
```

Galva presents its in-app messages on its own; see [Present messages yourself](https://github.com/Galva-io/galva-ios#present-messages-yourself) to control when they appear.

From now on, use RevenueCat as usual. `Purchases.shared.logIn("user_42")` identifies the Galva subscriber as `user_42`. If you followed Galva's docs and call `AppUser.identify(userId: Purchases.shared.appUserID)`, you can remove that call.

The order of the two `configure` calls doesn't matter. If RevenueCat is configured later, for example after an async step, the integration connects the next time your app becomes active. Until then, offers bought in Galva's messages use Galva's own StoreKit purchase.

### 3. Connect RevenueCat to Galva

The app integration covers your app. Galva also needs RevenueCat's subscription events, from its webhook:

1. In Galva, open **Admin → Settings → Connect → Billing Connections** and select **RevenueCat**.
2. In RevenueCat, create a V2 secret API key and add it to Galva.
3. In RevenueCat, add a webhook with Galva's webhook URL and authorization header, with every event type on.

See [Connect RevenueCat](https://docs.galva.io/integrations/revenuecat) for each step. The RevenueCat connection is in development.

### 4. Check it works

Run your app with `logLevel: .debug` in `Galva.configure`, and filter Console.app or Xcode's console on:

```
subsystem:co.galva.sdk category:integration
```

You should see `connected to RevenueCat`, with the RevenueCat version and mode. After `Purchases.shared.logIn`, you should see `identifying Galva user from RevenueCat`.

---

## If Galva uses different user IDs

By default, Galva's subscriber follows RevenueCat's app user ID. If you identify Galva with a different ID, keep your own `AppUser.identify` and `logOut` calls and tell the integration:

```swift
Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat(identity: .manual)])
```

Purchases and attributes still sync.

## What the integration does

### Identity

| In RevenueCat | In Galva |
|---|---|
| Logged in as `X` | `AppUser.identify(userId: "X")` |
| Switched from `X` to `Y` without logging out | `AppUser.logOut()`, then `identify(userId: "Y")` |
| Logged out, back to anonymous | `AppUser.logOut()` |
| Anonymous the whole time | Nothing. Galva may be identified separately. |

If the RevenueCat app user ID is a UUID, it's also passed as Galva's app account token. RevenueCat attaches that same UUID to the purchases it makes, so purchases from either SDK match the same subscriber.

### Purchases from Galva's messages

| RevenueCat `purchasesAreCompletedBy` | Regular offer | Galva-signed promotional offer |
|---|---|---|
| `.revenueCat` (default) | `Purchases.purchase(product:)`. RevenueCat records and finishes the transaction. | Galva's StoreKit purchase, since RevenueCat's API can't apply a Galva-signed offer. Then `syncPurchases()`, then the transaction is finished. |
| `.myApp` | Galva's StoreKit purchase, then `recordPurchase(_:)`. Your app finishes the transaction, as it does for its own purchases. | Same. |

The subscriber's app account token is attached to every purchase. If handing a purchase to RevenueCat fails, the subscriber doesn't see an error, because they've already paid. RevenueCat picks up the unfinished transaction on the next launch.

### Attributes

Each Galva subscriber gets these attributes, updated when they change:

| Attribute | Value |
|---|---|
| `$gv_rc_appUserId` | RevenueCat app user ID, including anonymous `$RCAnonymousID:…` IDs |
| `$gv_rc_originalAppUserId` | RevenueCat's original app user ID |
| `$gv_rc_activeEntitlements` | Identifiers of the active entitlements |

### Effect on your app

- **The sync stays off the main thread.** It runs on its own actor, and RevenueCat and StoreKit work in the background. The only main-thread work is deciding how to route a purchase someone starts in a Galva message.
- **Your `PurchasesDelegate` is untouched.** The integration listens to RevenueCat's `customerInfoStream`, which supports any number of listeners.
- **It installs Galva's purchase controller.** Don't call `Galva.setPurchaseController` yourself as well.
- **It watches for your app becoming active only while waiting for RevenueCat**, and stops once it connects.

Its log lines go through Galva's logger, under the `integration` category, and follow your `logLevel` and custom logger.

## Requirements

| | |
|---|---|
| **iOS** | 15.0 or later |
| **Xcode** | 26 or later, as for Galva |
| **RevenueCat** | 5.19.0 up to, but not including, 6.0.0, from `purchases-ios-spm`. With Xcode 27, RevenueCat itself needs 5.78.0 or later to compile. |

## License

MIT. See [LICENSE](LICENSE).
