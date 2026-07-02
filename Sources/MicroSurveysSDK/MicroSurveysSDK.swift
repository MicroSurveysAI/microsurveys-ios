//
//  MicroSurveysSDK.swift
//  MicroSurveysSDK iOS SDK
//
//  Public entry point. A host wires this up in ~3 lines:
//
//      let ms = MicroSurveysSDK(apiKey: "ms_live_xxx")
//      amplitude.add(plugin: ms.amplitudePlugin())   // forward events + identity
//      ms.start()                                     // fetch config + flush outbox
//
//  Optional, for non-Amplitude hosts or extra context:
//
//      ms.setUser(id: "user-123", properties: ["plan": "pro"])
//      ms.track("booking_completed", properties: ["amount": 42])
//
//  The instance owns the API client, config cache, identity store, trigger
//  engine, and (on UIKit) the presenter; it conforms to `MSEventForwarding` so
//  the Amplitude plugin can feed it.
//

import Foundation

#if canImport(AmplitudeSwift)
import AmplitudeSwift
#endif

#if canImport(UIKit)
import UIKit
#endif

public final class MicroSurveysSDK {

    /// MicroSurveysSDK project API key (public key, prefixed `ms_live_` or `ms_test_`).
    public let apiKey: String

    /// Base URL for the MicroSurveysSDK API. Override for self-hosted or staging.
    public let apiBaseURL: URL

    // MARK: Runtime collaborators

    private let apiClient: APIClient
    private let configStore: ConfigStore
    private let identityStore: IdentityStore
    private let triggerStateStore: TriggerStateStore
    private let engine: TriggerEngine

    #if canImport(UIKit)
    private let presenter = Presenter()
    private var foregroundObserver: NSObjectProtocol?
    #endif

    /// How long a cached config is treated as fresh. On app-foreground the SDK
    /// re-fetches only when the cache is older than this, so a long-lived app
    /// (suspended for days, never cold-launched) can't keep serving stale
    /// surveys/appearance. An unchanged fetch is a cheap ETag `304`.
    private static let configTTL: TimeInterval = 12 * 60 * 60

    public init(
        apiKey: String,
        apiBaseURL: URL = URL(string: "https://microsurveys.edubai.ventures")!
    ) {
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL

        let configStore = ConfigStore()
        let identityStore = IdentityStore()
        let triggerStateStore = TriggerStateStore()

        self.apiClient = APIClient(apiKey: apiKey, baseURL: apiBaseURL)
        self.configStore = configStore
        self.identityStore = identityStore
        self.triggerStateStore = triggerStateStore
        self.engine = TriggerEngine(store: triggerStateStore,
                                    identityProvider: { identityStore.snapshot() })

        configureEngine()
        applyCachedTheme()
        startLifecycleObserver()
    }

    private func configureEngine() {
        engine.surveysProvider = { [weak self] in
            self?.configStore.config?.surveys ?? []
        }
        engine.onPresent = { [weak self] survey, trigger, identity in
            self?.present(survey: survey, trigger: trigger, identity: identity)
        }
    }

    // MARK: Lifecycle

    /// Loads the cached config (already done at init), flushes any queued
    /// impressions/responses, and refreshes the config from the network.
    /// Safe to call once early in app launch.
    public func start() {
        MSLog.info("start: key=\(apiKey.prefix(11))…, base=\(apiBaseURL.absoluteString)")
        apiClient.flush()
        refreshConfig()
    }

    /// Re-fetches `/api/sdk/config` (ETag-aware) and updates the cache + theme.
    /// Foreground refresh is automatic (see `refreshConfigIfStale`); call this
    /// directly only to force an unconditional refresh.
    public func refreshConfig() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.apiClient.fetchConfig(etag: self.configStore.etag)
                switch result {
                case .notModified:
                    break
                case let .config(rawData, _, _, etag):
                    self.configStore.save(rawConfig: rawData, etag: etag)
                    self.applyCachedTheme()
                }
            } catch {
                // Keep the cached config; the SDK still works offline.
                MSLog.info("config fetch failed (\(error)); keeping cached config")
            }
        }
    }

    /// Re-fetches config only when the cache is missing or older than
    /// `configTTL` (12h). Fired automatically on app-foreground so long-lived
    /// apps refresh without the host wiring up a timer; safe to call manually.
    public func refreshConfigIfStale() {
        if let storedAt = configStore.storedAt,
           Date().timeIntervalSince(storedAt) < Self.configTTL {
            return
        }
        MSLog.info("config cache stale (TTL \(Int(Self.configTTL))s); refreshing")
        refreshConfig()
    }

    // MARK: Identity

    /// Identify the current user and/or attach properties used by `audienceMatch`.
    /// For Amplitude hosts this is optional — identity flows in via the plugin —
    /// but it's the primary path for non-Amplitude integrations.
    public func setUser(id: String?, properties: [String: Any] = [:]) {
        identityStore.setUser(id: id, properties: properties.isEmpty ? nil : properties)
    }

    // MARK: Manual events

    /// Record an event manually. Use this when not using Amplitude, or for
    /// events that don't flow through Amplitude's SDK. Pushed straight into the
    /// trigger engine with the current identity snapshot.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        engine.process(name: name, properties: properties)
    }

    /// Back-compat alias for `track(_:properties:)`.
    public func trackEvent(_ name: String, properties: [String: Any] = [:]) {
        track(name, properties: properties)
    }

    // MARK: Amplitude

    #if canImport(AmplitudeSwift)
    /// The enrichment plugin to register on your Amplitude instance:
    /// `amplitude.add(plugin: ms.amplitudePlugin())`. Forwards events + identity
    /// into the SDK and returns every event unmodified.
    public func amplitudePlugin() -> Plugin {
        MicroSurveysAmplitudePlugin(forwarder: self)
    }
    #endif

    // MARK: Presentation

    #if canImport(UIKit)
    /// Host override for where surveys present from. Defaults to the top-most
    /// view controller of the active scene's key window.
    public var presentationAnchor: (() -> UIViewController?)? {
        get { presenter.presentationAnchor }
        set { presenter.presentationAnchor = newValue }
    }

    /// Refreshes config on every app-foreground, throttled by `configTTL`.
    private func startLifecycleObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshConfigIfStale()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func applyCachedTheme() {
        let project = configStore.theme
        DispatchQueue.main.async { [weak self] in
            self?.presenter.theme = Presenter.makeTheme(from: project)
        }
        // If the theme names a Google Font that isn't registered yet, fetch it at runtime
        // (in memory — never bundled, never written to disk) and re-apply once it's available.
        if let family = project?.font, family != "system", !family.isEmpty,
           UIFont.fontNames(forFamilyName: family).isEmpty {
            GoogleFontLoader.load(family: family) { [weak self] ok in
                if ok { self?.applyCachedTheme() }
            }
        }
    }

    private func present(survey: Survey, trigger: Trigger, identity: MSIdentity) {
        let endUserId = identity.endUserId
        let userProps = identity.userProperties
        let shownAt = Date()

        presenter.present(survey: survey) { [weak self] result in
            guard let self, let result else { return }
            // Impression is finalized at close, so `dismissed` is authoritative.
            self.apiClient.recordImpression(surveyId: survey.id,
                                            triggerId: trigger.id,
                                            endUserId: endUserId,
                                            shownAt: shownAt,
                                            dismissed: result.dismissed)
            // A pure dismissal (closed with no answers) is an impression, NOT a response —
            // don't submit one, or it inflates the response count. Partial multi-step answers
            // (answered ≥1, then dropped) still count.
            if result.completed || !result.answers.isEmpty {
                self.apiClient.recordResponse(surveyId: survey.id,
                                              endUserId: endUserId,
                                              completed: result.completed,
                                              submittedAt: Date(),
                                              userProps: userProps,
                                              answers: result.answers)
            }
        }
    }
    #else
    /// No UIKit (e.g. `swift build` on macOS): theme/presentation/lifecycle are no-ops.
    private func startLifecycleObserver() {}
    private func applyCachedTheme() {}
    private func present(survey: Survey, trigger: Trigger, identity: MSIdentity) {}
    #endif
}

// MARK: - Logging

public extension MicroSurveysSDK {
    /// Verbose SDK logging to the Xcode console. Defaults to ON in DEBUG builds and OFF in release.
    /// Filter the console by "[MicroSurveys]" to see events, trigger decisions (and skip reasons),
    /// presentation, and network calls.
    static var loggingEnabled: Bool {
        get { MSLog.level != .off }
        set { MSLog.level = newValue ? .debug : .off }
    }
}

// MARK: - MSEventForwarding

extension MicroSurveysSDK: MSEventForwarding {
    func forwardIdentity(userId: String?, deviceId: String?, userProperties: [String: Any]?) {
        identityStore.updateFromAmplitude(userId: userId,
                                          deviceId: deviceId,
                                          userProperties: userProperties)
    }

    func forwardEvent(name: String, properties: [String: Any]) {
        engine.process(name: name, properties: properties)
    }
}
