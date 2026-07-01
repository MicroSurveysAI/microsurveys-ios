//
//  AmplitudePlugin.swift
//  MicroSurveysSDK
//
//  An Amplitude enrichment plugin that taps the host's existing Amplitude
//  instance: it reads every tracked event (name + properties), keeps an
//  identity snapshot fresh, and forwards both to the SDK — then returns the
//  event **unmodified** (pure pass-through, never drops or rewrites events).
//
//  Compiled only when Amplitude-Swift is linked; non-Amplitude hosts drive the
//  SDK via `track(_:properties:)` instead.
//

import Foundation

/// What the plugin forwards into. Platform-free so the SDK can conform without
/// importing UIKit/Amplitude. Implemented by `MicroSurveysSDK`.
protocol MSEventForwarding: AnyObject {
    /// A refreshed identity snapshot (userId/deviceId/user properties). Any
    /// argument may be `nil` when unavailable.
    func forwardIdentity(userId: String?, deviceId: String?, userProperties: [String: Any]?)
    /// A tracked event to evaluate against triggers.
    func forwardEvent(name: String, properties: [String: Any])
}

#if canImport(AmplitudeSwift)
import AmplitudeSwift

/// Enrichment plugin registered via `amplitude.add(plugin:)`.
public final class MicroSurveysAmplitudePlugin: Plugin {

    public let type: PluginType = .enrichment
    public weak var amplitude: Amplitude?

    private weak var forwarder: MSEventForwarding?

    init(forwarder: MSEventForwarding) {
        self.forwarder = forwarder
    }

    public func setup(amplitude: Amplitude) {
        self.amplitude = amplitude
        // Capture whatever identity is known at registration time.
        refreshIdentity(from: nil)
        MSLog.info("Amplitude plugin registered (enrichment)")
    }

    public func execute(event: BaseEvent) -> BaseEvent? {
        // Keep the identity snapshot current. On `$identify` we also harvest the
        // user properties carried by the event.
        refreshIdentity(from: event)

        // Forward the event for trigger evaluation. System events (`$...`) won't
        // match host-defined triggers, but are cheap to pass through.
        let name = event.eventType
        let properties = event.eventProperties ?? [:]
        MSLog.debug("amplitude event '\(name)'\(properties.isEmpty ? "" : " \(properties)")")
        forwarder?.forwardEvent(name: name, properties: properties)

        // Pass-through: never modify or drop the event.
        return event
    }

    public func teardown() {
        amplitude = nil
    }

    // MARK: Identity

    private func refreshIdentity(from event: BaseEvent?) {
        // Primary path: public accessors that exist across Amplitude-Swift
        // versions. TODO: if a build exposes `amplitude.identity.userId /
        // .deviceId / .userProperties` directly, prefer that single snapshot.
        let userId = amplitude?.getUserId()
        let deviceId = amplitude?.getDeviceId()

        var userProperties: [String: Any]? = nil
        if let event, event.eventType == "$identify" {
            userProperties = Self.userProperties(from: event)
        }

        forwarder?.forwardIdentity(userId: userId, deviceId: deviceId, userProperties: userProperties)
    }

    /// Extracts the flattened user properties from an `$identify` event. The
    /// operations are nested under keys like `$set`; we read `$set` when present
    /// and otherwise fall back to the raw map.
    /// TODO: handle `$unset` / `$add` if audiences ever need them.
    private static func userProperties(from event: BaseEvent) -> [String: Any]? {
        guard let ops = event.userProperties else { return nil }
        if let set = ops["$set"] as? [String: Any] { return set }
        return ops
    }
}
#endif
