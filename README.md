# MicroSurveys iOS SDK

Native, contextual in-app micro-surveys for **UIKit & SwiftUI** apps — ask the
right user the right question at the right moment, triggered by the events you
already track. No WebViews, no new instrumentation.

- **Platforms:** iOS 14+ · Swift 5.9 · UIKit & SwiftUI
- **Analytics:** works with [Amplitude](https://amplitude.com) out of the box, or
  drive it manually with a single `track(...)` call — your choice.
- **Question types:** NPS, CSAT, CES, thumbs, stars, single-choice, emoji, open text.

## Install (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/MicroSurveysAI/microsurveys-ios
```

Or in your `Package.swift`:

```swift
.package(url: "https://github.com/MicroSurveysAI/microsurveys-ios.git", from: "0.0.1")
```

Then add `MicroSurveysSDK` to your target's dependencies.

## Quick start

```swift
import MicroSurveysSDK
import AmplitudeSwift

let ms = MicroSurveysSDK(apiKey: "ms_live_xxx")   // your project's public API key
amplitude.add(plugin: ms.amplitudePlugin())        // forward events + identity
ms.start()                                          // load config + flush outbox
```

That's it — published surveys now trigger off your existing Amplitude events.

**No Amplitude?** Drive it manually:

```swift
ms.setUser(id: "user-123", properties: ["plan": "pro"])
ms.track("booking_completed", properties: ["amount": 42])   // manual trigger
```

## How it works

You publish a survey in the dashboard with a **trigger** (e.g. `page_view` on
`screen=Wallet`) plus eligibility rules (audience, sampling, frequency, per-user
cap, schedule) and a brand theme. The SDK caches the config on device, matches
every event against active triggers, and renders the survey natively when a user
is eligible.

## Docs

- **Full integration guide:** [`INTEGRATION.md`](./INTEGRATION.md)
- **Documentation:** https://docs.microsurveys.ai
- **Dashboard:** https://console.microsurveys.ai

---

© MicroSurveys
