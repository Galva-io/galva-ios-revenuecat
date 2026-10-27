# GalvaRevenueCat

Connect the [Galva iOS SDK](https://github.com/Galva-io/galva-ios) to [RevenueCat](https://www.revenuecat.com) with one line:

```swift
Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat()])
```

- **Offers bought in Galva's messages go through RevenueCat.** RevenueCat records the transaction, and the subscriber's entitlement unlocks right away. Without this, RevenueCat only sees those purchases on the next launch.
- **Galva follows RevenueCat's identity.** `Purchases.logIn` and `logOut` identify and log out the Galva subscriber too, so you don't call `AppUser.identify` yourself.
- **Both SDKs agree on purchases.** Galva matches each new purchase to the subscriber who made it, including purchases from your own RevenueCat paywall, right away.

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
import SwiftUI

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

From now on, use RevenueCat as usual. Within two seconds, `Purchases.shared.logIn("user_42")` identifies the Galva subscriber as `user_42`. If you followed Galva's docs and call `AppUser.identify(userId: Purchases.shared.appUserID)`, you can remove that call.

The order of the two `configure` calls doesn't matter. If RevenueCat is configured later, for example after an async step, the integration connects within two seconds while your app is active. Until then, offers bought in Galva's messages use Galva's own StoreKit purchase.

### 3. Connect RevenueCat to Galva

The app integration covers your app. Galva also needs your subscription data: RevenueCat forwards the App Store Server Notifications it receives to Galva, and a secret API key lets Galva match each purchase to a subscriber.

1. In Galva, open **Admin → Settings → Connect → Billing Connections** and select **RevenueCat**.
2. In RevenueCat, create a V2 secret API key with read-only access to customer information. Give Galva the key and your RevenueCat project ID.
3. In RevenueCat, open your iOS app's **Apple Server to Server notification settings** and paste Galva's relay URL into **Apple Server Notification Forwarding URL**. Galva doesn't use a RevenueCat webhook.

See [Connect RevenueCat](https://docs.galva.io/integrations/revenuecat#send-subscription-data-through-revenuecat) for each step. The RevenueCat connection is in development: for now, the Galva team adds your key and project ID and gives you the relay URL.

### 4. Check it works

Run your app with `logLevel: .debug` in `Galva.configure`, and filter Console.app or Xcode's console on:

```
subsystem:co.galva.sdk category:integration
```

You should see `connected to RevenueCat`, with the RevenueCat version and mode. Within two seconds of `Purchases.shared.logIn`, you should see `identifying Galva user from RevenueCat`.

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
| Starts a launch as `X` while Galva is identified as someone else, for example after `Purchases.configure(withAPIKey:appUserID:)` | `AppUser.logOut()`, then `identify(userId: "X")` |
| Logged out just before the app quit | `AppUser.logOut()` at the next launch, even offline |
| Anonymous the whole time | Nothing. Galva may be identified separately. |

RevenueCat reports changes to its customer, not to its app user ID. Its `customerInfoStream` sends nothing when `logIn` merges an anonymous user into a new ID, the usual sign-up, and nothing after `logOut` until RevenueCat has fetched its new anonymous user. So the integration reads RevenueCat's app user ID every two seconds while your app is active. Each time your app becomes active, it also reads RevenueCat's user and the customer info RevenueCat has cached for them. A `logIn` or `logOut` reaches Galva within two seconds, offline too.

To catch changes from a previous launch, the integration remembers the RevenueCat app user ID it last passed to Galva. At launch, as soon as RevenueCat is configured, it compares that, and RevenueCat's current user, with Galva's current subscriber. While RevenueCat is anonymous, it logs out only a Galva subscriber it identified itself, so one your app identified stays until RevenueCat logs in as someone else.

The integration never sets Galva's app account token. RevenueCat doesn't expose the token it attaches to its purchases, so Galva keeps its own and matches every purchase to the subscriber by its transaction ID, as described below.

### Purchases from Galva's messages

| RevenueCat `purchasesAreCompletedBy` | Regular offer | Promotional offer |
|---|---|---|
| `.revenueCat` (default) | `Purchases.purchase(product:)`. RevenueCat records and finishes the transaction. | `Purchases.purchase(product:promotionalOffer:)`, with the offer signed by RevenueCat. RevenueCat records and finishes the transaction. |
| `.myApp` | Galva's StoreKit purchase, then `recordPurchase(_:)`. The transaction stays unfinished for your app to finish. | Same, with the offer signed by Galva. |

RevenueCat's API can't take the signature Galva makes for a promotional offer, so RevenueCat signs the same App Store offer itself, with the In-App Purchase key in your RevenueCat project. RevenueCat 5 needs that key to record StoreKit 2 purchases anyway, so with `.revenueCat` you don't need to add it to Galva: without it, Galva sends the offer unsigned. With `.myApp`, Galva's StoreKit purchase needs Galva's signature, so add the key in Galva. If RevenueCat's key is missing, the message shows an error, and the integration logs how to fix it. RevenueCat also won't sign an offer for someone with no subscription in the offer's group on the device, since Apple gives promotional offers only to current and past subscribers.

Galva's StoreKit purchase attaches the subscriber's Galva app account token; the integration uses it with `.myApp`, and until RevenueCat is configured. RevenueCat's purchases attach whatever token RevenueCat chooses, which its API doesn't expose. Either way, after every completed purchase the integration calls `Galva.reconcileTransactions()`, which matches the new transaction to the current subscriber by its transaction ID.

With `.myApp`, StoreKit doesn't put the transaction on `Transaction.updates`, and the integration has no callback for it. Your app picks it up from `Transaction.unfinished`, at launch and whenever it becomes active, and finishes it, as in Galva's [Finish offer purchases](https://github.com/Galva-io/galva-ios#6-finish-offer-purchases) step.

If handing a purchase to RevenueCat fails, the subscriber doesn't see an error, because they've already paid, and RevenueCat picks up the unfinished transaction on the next launch.

A RevenueCat purchase can also fail after StoreKit charged the subscriber, when only RevenueCat's post of the purchase to its server failed. The integration then finds the new transaction in StoreKit and reports the purchase as completed. It also calls `syncPurchases()`, because when RevenueCat's server rejects the post, RevenueCat finishes the transaction and doesn't post it again. A consumable finished that way no longer appears in StoreKit, so for that case the message shows RevenueCat's error.

### Attributes

Each Galva subscriber gets these attributes, from RevenueCat's cached customer info as soon as the integration connects, then whenever they change. When the Galva subscriber changes, including when your app switches users with `.manual`, they're sent again the next time your app becomes active, or with the next RevenueCat update if that comes first.

| Attribute | Value |
|---|---|
| `$gv_rc_appUserId` | RevenueCat app user ID, including anonymous `$RCAnonymousID:…` IDs |
| `$gv_rc_originalAppUserId` | RevenueCat's original app user ID |
| `$gv_rc_activeEntitlements` | Identifiers of the active entitlements |

### Effect on your app

- **The sync stays off the main thread.** It runs on its own actor, and RevenueCat and StoreKit work in the background. The only main-thread work is deciding how to route a purchase someone starts in a Galva message.
- **Your `PurchasesDelegate` is untouched.** The integration listens to RevenueCat's `customerInfoStream`, which supports any number of listeners.
- **It installs Galva's purchase controller.** Don't call `Galva.setPurchaseController` yourself as well.
- **It checks RevenueCat's app user ID every two seconds while your app is active.** RevenueCat keeps the ID in memory, so the check is cheap. The integration reads RevenueCat's cached customer info only when your app becomes active or that ID changes, and nothing runs while your app isn't active.
- **It stores one value**: the RevenueCat app user ID it last passed to Galva, in `UserDefaults`, under a `co.galva.revenuecat.` key. Its privacy manifest declares that use, so you don't have to.

Its log lines go through Galva's logger, under the `integration` category, and follow your `logLevel` and custom logger.

## Requirements

| | |
|---|---|
| **iOS** | 15.0 or later |
| **Xcode** | 26 or later, as for Galva. With an older Xcode, SwiftPM stops when resolving the package. |
| **RevenueCat** | 5.19.0 up to, but not including, 6.0.0, from `purchases-ios-spm` through Swift Package Manager. With Xcode 27 the package requires 5.78.0 or later, since earlier RevenueCat releases don't compile there; an app pinned to one gets a resolution error naming the version it needs. |

## License

MIT. See [LICENSE](LICENSE).
