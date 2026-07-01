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
        // Prime from the current snapshot (usually empty at launch — properties are set lazily,
        // so the real population happens per-event in execute()).
        refreshIdentity()
        MSLog.info("Amplitude plugin registered (enrichment)")
    }

    public func execute(event: BaseEvent) -> BaseEvent? {
        // Read Amplitude's live identity snapshot per event. Amplitude applies $set/$unset to
        // `amplitude.identity` as $identify events flow through the timeline, so this gives the
        // complete, current user properties — independent of when identify fires or plugin order,
        // and it survives restarts (Amplitude persists identity).
        refreshIdentity()

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

    /// Forward Amplitude's current identity snapshot. `amplitude.identity` (Amplitude-Swift 1.18+)
    /// is a thread-safe value copy carrying userId/deviceId and the current userProperties (all
    /// `$set` operations applied). Reading it per event means we always have the complete, current
    /// set for audience matching.
    private func refreshIdentity() {
        guard let amplitude else { return }
        let snapshot = amplitude.identity
        forwarder?.forwardIdentity(
            userId: snapshot.userId,
            deviceId: snapshot.deviceId,
            userProperties: snapshot.userProperties
        )
    }
}
#endif
