//
//  IdentityStore.swift
//  MicroSurveysSDK
//
//  Maintains the current `MSIdentity` snapshot the engine evaluates against,
//  merging signals from Amplitude (userId/deviceId/identify properties) and the
//  host (`setUser`). Generates and persists a stable anonymous id so cap and
//  trigger state stay consistent across launches before any user is identified.
//

import Foundation

final class IdentityStore {

    private let defaults: UserDefaults
    private let anonKey = "com.microsurveys.anonymousId"
    private let lock = NSLock()
    private var identity: MSIdentity

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load or mint a stable anonymous id.
        let anon: String
        if let existing = defaults.string(forKey: anonKey) {
            anon = existing
        } else {
            anon = "anon_" + UUID().uuidString
            defaults.set(anon, forKey: anonKey)
        }
        self.identity = MSIdentity(anonymousId: anon)
    }

    /// Thread-safe snapshot for evaluation.
    func snapshot() -> MSIdentity {
        lock.lock(); defer { lock.unlock() }
        return identity
    }

    /// Merge an Amplitude identity update (from the enrichment plugin).
    func updateFromAmplitude(userId: String?, deviceId: String?, userProperties: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        if let userId { identity.amplitudeUserId = userId }
        if let deviceId { identity.amplitudeDeviceId = deviceId }
        if let props = userProperties {
            for (key, value) in props {
                identity.userProperties[key] = JSONValue(any: value)
            }
        }
    }

    /// Apply a host `setUser(id:properties:)` call.
    func setUser(id: String?, properties: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        if let id { identity.hostUserId = id }
        if let props = properties {
            for (key, value) in props {
                identity.userProperties[key] = JSONValue(any: value)
            }
        }
    }
}
