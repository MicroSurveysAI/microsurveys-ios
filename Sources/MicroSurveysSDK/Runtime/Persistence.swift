//
//  Persistence.swift
//  MicroSurveysSDK
//
//  On-disk state so the SDK works immediately/offline and trigger progress
//  survives app restarts:
//   • ConfigStore       — the latest SDKConfig + theme + ETag.
//   • TriggerStateStore — per-(endUserId) sequence progress, occurrence
//     counters, sticky sampling, and last-shown timestamps for the cap.
//
//  Both persist via UserDefaults (simple, synchronous, app-sandboxed). The
//  contract allows Caches dir; UserDefaults keeps it dependency-free and
//  testable by injecting a custom suite.
//

import Foundation

// MARK: - ConfigStore

/// Persists the most recent `/api/sdk/config` result so the SDK can evaluate
/// triggers and render surveys immediately on launch, before (or without) a
/// successful network refresh.
///
/// We store the **raw response bytes** (not a re-encoded `SDKConfig`): the
/// `Question` model encodes lossily on purpose (it drops `config`), so a Codable
/// round-trip would strip choice/emoji options. Re-decoding the original bytes
/// is lossless.
final class ConfigStore {

    private struct Persisted: Codable {
        let rawConfig: Data
        let etag: String?
        let storedAt: Date
    }

    private let defaults: UserDefaults
    private let key = "com.microsurveys.config.cache"
    private let lock = NSLock()

    private var persisted: Persisted?
    private var decodedConfig: SDKConfig?
    private var decodedTheme: ProjectTheme?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let entry = try? JSONDecoder().decode(Persisted.self, from: data) {
            persisted = entry
            decode(entry.rawConfig)
        }
    }

    /// The cached, losslessly-decoded config (loaded on init).
    var config: SDKConfig? {
        lock.lock(); defer { lock.unlock() }
        return decodedConfig
    }

    /// The cached project theme.
    var theme: ProjectTheme? {
        lock.lock(); defer { lock.unlock() }
        return decodedTheme
    }

    /// Last known ETag, for conditional `If-None-Match` requests.
    var etag: String? {
        lock.lock(); defer { lock.unlock() }
        return persisted?.etag
    }

    /// When the cached config was last written, for TTL-based freshness checks.
    /// `nil` when nothing has been cached yet.
    var storedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return persisted?.storedAt
    }

    /// Persists the raw config response and refreshes the in-memory decode.
    func save(rawConfig: Data, etag: String?) {
        let entry = Persisted(rawConfig: rawConfig, etag: etag, storedAt: Date())
        lock.lock()
        persisted = entry
        decode(rawConfig)
        lock.unlock()
        if let data = try? JSONEncoder().encode(entry) {
            defaults.set(data, forKey: key)
        }
    }

    /// Assumes the caller holds `lock` (init) or is inside `save`'s lock.
    private func decode(_ data: Data) {
        decodedConfig = try? JSONDecoder().decode(SDKConfig.self, from: data)
        decodedTheme = (try? JSONDecoder().decode(ThemeEnvelope.self, from: data))?.theme
    }
}

// MARK: - Trigger state

/// Per-trigger progress for a single user.
struct TriggerRecord: Codable {
    /// Next sequence step index expected (0 = waiting for step 0). Always 0 for
    /// SINGLE triggers.
    var stepIndex: Int = 0
    /// Unix time when step 0 was matched, to enforce `sequenceWindowSeconds`.
    var startedAt: TimeInterval?
    /// How many times this trigger's full condition has been satisfied — drives
    /// `warmupCount` + `fireEvery`.
    var satisfiedCount: Int = 0
}

/// Per-survey state for a single user.
struct SurveyRecord: Codable {
    /// Unix time the survey was last shown to this user, for `maxPerUserDays`.
    var lastShownAt: TimeInterval?
    /// Sticky sampling decision (computed once, reused forever).
    var sampleDecision: Bool?
}

/// The full persisted state for one `endUserId`.
struct UserTriggerState: Codable {
    var triggers: [String: TriggerRecord] = [:]   // keyed by triggerId
    var surveys: [String: SurveyRecord] = [:]      // keyed by surveyId
}

/// Loads/saves `UserTriggerState` keyed by `endUserId`. Cheap enough to read &
/// rewrite the whole blob per evaluation for MVP volumes.
final class TriggerStateStore {

    private let defaults: UserDefaults
    private let prefix = "com.microsurveys.triggerstate."
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(endUserId: String) -> UserTriggerState {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: prefix + endUserId),
              let state = try? JSONDecoder().decode(UserTriggerState.self, from: data)
        else { return UserTriggerState() }
        return state
    }

    func save(endUserId: String, state: UserTriggerState) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: prefix + endUserId)
        }
    }

    /// Test/utility helper.
    func reset(endUserId: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: prefix + endUserId)
    }
}
