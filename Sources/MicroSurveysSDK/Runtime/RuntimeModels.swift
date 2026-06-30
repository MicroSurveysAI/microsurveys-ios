//
//  RuntimeModels.swift
//  MicroSurveysSDK
//
//  Runtime-only types that aren't part of the rendered survey contract:
//  the project theme delivered by `/api/sdk/config`, the identity snapshot the
//  engine evaluates against, the manual/Amplitude event shape, and the
//  Encodable payloads for the impressions/responses ingest endpoints.
//
//  Intentionally UIKit-free; theme → `SurveyTheme` mapping lives in Presenter.
//

import Foundation

// MARK: - Project theme (from /api/sdk/config top-level `theme`)

/// Brand-level survey appearance, configured in the dashboard and delivered in
/// the config payload. All keys optional; `{}` ⇒ SDK defaults. Mapped onto
/// `SurveyTheme` by the presenter (see API-CONTRACT §Theme).
public struct ProjectTheme: Codable, Equatable {
    public let accent: String?
    public let accentText: String?
    public let background: String?
    public let surface: String?
    public let text: String?
    public let secondaryText: String?
    public let border: String?
    public let cornerRadius: Double?
    /// `"bottom"` | `"center"`. The MVP renderer is bottom-sheet only; `center`
    /// is recorded but not yet honored (TODO in Presenter).
    public let position: String?
    /// `"system"` or a host-bundled font family name. Custom families are not
    /// yet resolved by the renderer (TODO in Presenter).
    public let font: String?
}

/// Used to pull the top-level `theme` object out of the config payload without
/// modifying the `SDKConfig` model (which decodes only `projectId`/`surveys`).
struct ThemeEnvelope: Decodable {
    let theme: ProjectTheme?
}

// MARK: - Identity snapshot

/// A point-in-time view of who the current user is and what we know about them.
/// Refreshed from Amplitude's identity store (via the enrichment plugin) and/or
/// `setUser(id:properties:)`, and snapshotted into each evaluation.
public struct MSIdentity: Equatable {
    /// Amplitude user id (set via `amplitude.setUserId` / login).
    public var amplitudeUserId: String?
    /// Amplitude device id (always present once Amplitude initializes).
    public var amplitudeDeviceId: String?
    /// Host-supplied id from `setUser(id:)`, for non-Amplitude integrations.
    public var hostUserId: String?
    /// Stable, persisted anonymous id — the final fallback so eligibility/cap
    /// state is consistent across launches even with no identified user.
    public var anonymousId: String
    /// User properties used for `audienceMatch` (Amplitude identify props
    /// merged with host-supplied context).
    public var userProperties: [String: JSONValue]

    public init(amplitudeUserId: String? = nil,
                amplitudeDeviceId: String? = nil,
                hostUserId: String? = nil,
                anonymousId: String,
                userProperties: [String: JSONValue] = [:]) {
        self.amplitudeUserId = amplitudeUserId
        self.amplitudeDeviceId = amplitudeDeviceId
        self.hostUserId = hostUserId
        self.anonymousId = anonymousId
        self.userProperties = userProperties
    }

    /// `endUserId` = Amplitude userId ?? deviceId ?? host id ?? anonymous id.
    public var endUserId: String {
        amplitudeUserId ?? amplitudeDeviceId ?? hostUserId ?? anonymousId
    }
}

// MARK: - Event

/// A normalized event fed to the engine, from Amplitude's enrichment plugin or
/// a manual `track(_:properties:)` call.
public struct MSEvent {
    public let name: String
    public let properties: [String: Any]

    public init(name: String, properties: [String: Any] = [:]) {
        self.name = name
        self.properties = properties
    }
}

// MARK: - Ingest payloads (Encodable; match API-CONTRACT §2 / §3)

struct ImpressionPayload: Encodable {
    let clientId: String
    let surveyId: String
    let triggerId: String?
    let endUserId: String
    let shownAt: String      // ISO-8601 UTC
    let dismissed: Bool
}

struct ImpressionBatch: Encodable {
    let impressions: [ImpressionPayload]
}

struct ResponsePayload: Encodable {
    let clientId: String
    let surveyId: String
    let endUserId: String
    let completed: Bool
    let submittedAt: String  // ISO-8601 UTC
    let userProps: [String: JSONValue]
    let answers: [SurveyAnswer]
}

struct ResponseBatch: Encodable {
    let responses: [ResponsePayload]
}

// MARK: - Any → JSONValue bridging

public extension JSONValue {
    /// Best-effort conversion of an arbitrary host/Amplitude value into a
    /// `JSONValue`, used to snapshot user properties for `audienceMatch`.
    init(any value: Any?) {
        guard let value = value else { self = .null; return }
        switch value {
        case let v as JSONValue:        self = v
        case let s as String:           self = .string(s)
        case let b as Bool:             self = .bool(b)
        case let i as Int:              self = .number(Double(i))
        case let d as Double:           self = .number(d)
        case let f as Float:            self = .number(Double(f))
        case let n as NSNumber:         self = .number(n.doubleValue)
        case let dict as [String: Any]: self = .object(dict.mapValues { JSONValue(any: $0) })
        case let arr as [Any]:          self = .array(arr.map { JSONValue(any: $0) })
        default:                        self = .string("\(value)")
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Snapshots a loosely-typed property bag into `[String: JSONValue]`.
    func asJSONValues() -> [String: JSONValue] {
        mapValues { JSONValue(any: $0) }
    }
}

// MARK: - Shared ISO-8601 formatter

enum MSTime {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String { iso8601.string(from: date) }
    static func date(from string: String) -> Date? { iso8601.date(from: string) }
}
