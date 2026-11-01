//
//  Debug.swift
//  MicroSurveysSDK iOS SDK
//
//  The live debugger: on a test device chosen in the dashboard, the SDK sends
//  each tracked event and what the engine decided for every survey whose trigger
//  names it, so a developer can see why a survey did or didn't show.
//
//  The dashboard never sends test user ids to apps. Config carries `debugUsers`,
//  hashes of "debug:<projectId>:<userId>"; the SDK hashes its current user the
//  same way and only reports on a match. Same FNV-1a as sampling, so every SDK
//  computes the same value.
//

import Foundation

enum DebugKey {
    /// The hash the dashboard puts in config `debugUsers` for one test user.
    static func make(projectId: String, endUserId: String) -> String {
        let hash = Sampling.fnv1a32("debug:\(projectId):\(endUserId)")
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }
}

struct DebugEntry: Encodable {
    let at: String
    /// The tracked event, or nil for a decision made later (shown, capped at fire time).
    let event: String?
    let properties: [String: JSONValue]
    let decisions: [Decision]

    private static let maxProps = 30
    private static let maxString = 200

    /// A small, JSON-safe copy of an event's properties for display. Test devices
    /// only; nested values are summarised rather than sent whole.
    static func displayProperties(_ properties: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for key in properties.keys.sorted().prefix(maxProps) {
            switch properties[key] {
            case let v as String:
                out[key] = .string(v.count > maxString ? String(v.prefix(maxString)) + "…" : v)
            case let v as Bool:
                out[key] = .bool(v)
            case let v as NSNumber:
                out[key] = .number(v.doubleValue)
            case let v as [Any]:
                out[key] = .string("[\(v.count) items]")
            case is [String: Any]:
                out[key] = .string("{…}")
            case nil, is NSNull:
                out[key] = .null
            default:
                out[key] = .string(String(describing: properties[key]!))
            }
        }
        return out
    }
}

struct DebugBatch: Encodable {
    let entries: [DebugEntry]
    let endUserId: String
    let context: EventCountsBatch.Context
}
