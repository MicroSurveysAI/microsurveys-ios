# MicroSurveysSDK — iOS Integration

Add live in-app micro-surveys to your app. The SDK fetches your published survey
config, listens to your Amplitude events, evaluates triggers locally, and
presents the right survey at the right time — no per-survey host code.

> Status: **UNVERIFIED** — this runtime layer was written without a Swift
> toolchain (Linux). Build it in Xcode on a Mac; expect to fix minor compile
> errors (notably the Amplitude identity API, see *Assumptions* below).

## 1. Add the package (Swift Package Manager)

Local package (monorepo):

```swift
// In your app's Package.swift, or Xcode → Add Package → Add Local…
.package(path: "../MicroSurveysSDK/sdk-ios")
```

Or by URL once published:

```swift
.package(url: "https://github.com/MicroSurveysAI/microsurveys-ios", from: "0.1.0")
```

Then add `MicroSurveysSDK` to your target's dependencies. The package links
`Amplitude-Swift`; the Amplitude integration is conditionally compiled, so apps
without Amplitude still build and can drive the SDK manually.

## 2. Wire it up (the 3 lines)

```swift
import MicroSurveysSDK
import AmplitudeSwift

let ms = MicroSurveysSDK(apiKey: "ms_live_xxx")   // your project's public API key
amplitude.add(plugin: ms.amplitudePlugin())        // forward events + identity
ms.start()                                          // fetch /api/sdk/config + flush outbox
```

- `amplitudePlugin()` returns an **enrichment** plugin that reads every tracked
  event and keeps an identity snapshot fresh. It returns each event **unmodified**
  (pure pass-through — it never drops or alters your analytics).
- `start()` loads the cached config immediately (so it works offline / on first
  frame), flushes any queued impressions/responses from a previous offline
  session, and refreshes config from the network (ETag-aware).

### Optional: non-Amplitude hosts / extra context

```swift
ms.setUser(id: "user-123", properties: ["plan": "pro"])      // identity + audience props
ms.track("booking_completed", properties: ["amount": 42])    // manual trigger event
```

`track(...)` feeds the same trigger engine as the Amplitude plugin, so you can
use either or both.

### Optional: control where surveys appear

```swift
ms.presentationAnchor = { myTopViewController }   // defaults to the active scene's top VC
```

## 3. How a published survey reaches the screen

1. In the dashboard you publish a survey with a **trigger** (e.g. `page_view`
   on `screen=Wallet`, then `wallet_tap`) and eligibility rules (audience,
   sampling %, frequency, per-user cap, schedule window) plus a brand **theme**.
2. `GET /api/sdk/config` returns all ACTIVE surveys + the project theme; the SDK
   caches it to disk.
3. Each Amplitude event (or `ms.track(...)`) is matched against every active
   survey's trigger. When a trigger's full condition is satisfied, the SDK
   applies the eligibility order from the API contract:
   **window → trigger → frequency → audience → sampling → cap.**
4. If eligible, the survey is scheduled after `delaySeconds` (the cap is
   re-checked at fire time) and presented on the top-most view controller using
   your dashboard theme.
5. On close the SDK POSTs an **impression** (`dismissed` reflects the outcome)
   and a **response** (answers + completion). Both carry a UUID `clientId` and
   are queued in a small disk outbox, so offline submissions flush on next launch.

Trigger progress, occurrence counters, sticky sampling decisions, and last-shown
timestamps persist per `endUserId` across app restarts.

`endUserId` = Amplitude `userId` → `deviceId` → host `setUser(id:)` → a generated,
persisted anonymous id.

## Assumptions / TODOs (resolve during the Xcode build)

- **Amplitude identity API:** the plugin reads `amplitude.getUserId()` /
  `amplitude.getDeviceId()` and harvests user properties from `$identify`
  events. If your Amplitude-Swift version exposes `amplitude.identity.userId /
  .deviceId / .userProperties`, prefer that single snapshot (see TODO in
  `Runtime/AmplitudePlugin.swift`).
- **Theme `position` / `font`:** the renderer is bottom-sheet + system-font only
  for MVP; `position: "center"` and custom font families are decoded but not yet
  applied (TODO in `Runtime/Presenter.swift`).
