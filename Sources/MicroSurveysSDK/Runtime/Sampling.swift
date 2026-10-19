//
//  Sampling.swift
//  MicroSurveysSDK
//
//  Pure, platform-free helpers used by the trigger engine: deterministic
//  FNV-1a sampling and the equality `match` / `audienceMatch` evaluator.
//  Kept UIKit-free so the unit tests run on macOS/Linux without a simulator.
//

import Foundation

// MARK: - Deterministic sampling

/// Deterministic, sticky sampling. The same `(endUserId, surveyId)` pair always
/// yields the same decision, with no server round-trip — see API-CONTRACT
/// §Sampling. Uses 32-bit FNV-1a so the result is reproducible if the backend
/// ever computes it too.
public enum Sampling {

    /// 32-bit FNV-1a hash of `string`'s UTF-8 bytes.
    public static func fnv1a32(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5            // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193            // FNV prime, wrapping multiply
        }
        return hash
    }

    /// `inSample = FNV-1a(endUserId + ":" + surveyId) % 100 < samplePercent`.
    /// `samplePercent` is clamped to `0...100`; `>= 100` always samples in and
    /// `<= 0` always samples out.
    public static func inSample(endUserId: String, surveyId: String, samplePercent: Int) -> Bool {
        if samplePercent >= 100 { return true }
        if samplePercent <= 0 { return false }
        let bucket = Int(fnv1a32("\(endUserId):\(surveyId)") % 100)
        return bucket < samplePercent
    }
}

// MARK: - Equality matching

/// Evaluates the equality filters used by triggers (`step.match`) and audiences
/// (`survey.audienceMatch`). All comparisons are done by stringifying both sides
/// — the wire contract is equality-only for MVP (no `gt`/`in`/`contains`).
public enum MatchEvaluator {

    /// Stringifies an arbitrary event-property value for comparison. Returns
    /// `nil` for values we can't meaningfully compare (e.g. nested containers).
    ///
    /// - Note: On Apple platforms JSON booleans and numbers both bridge to
    ///   `NSNumber`, so a boolean *could* be read as `0/1`. We check `Bool`
    ///   before the integer types to minimise this; host-supplied native Swift
    ///   values are unaffected. TODO: revisit if a host reports bool/number
    ///   confusion in `match` filters.
    public static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String:  return s
        case let b as Bool:    return b ? "true" : "false"
        case let i as Int:     return String(i)
        case let i as Int64:   return String(i)
        case let i as UInt:    return String(i)
        case let d as Double:  return numberString(d)
        case let f as Float:   return numberString(Double(f))
        case let n as NSNumber: return numberString(n.doubleValue)
        default:               return nil
        }
    }

    /// Stringifies a `JSONValue` (the type used by `match` / `audienceMatch`).
    /// Returns `nil` for `null` and containers, which never participate in an
    /// equality match.
    public static func stringify(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .bool(let b):   return b ? "true" : "false"
        case .number(let n): return numberString(n)
        case .null, .object, .array: return nil
        }
    }

    /// Formats a double as an integer when it has no fractional part, so
    /// `42` (Int) and `42.0` (JSON number) compare equal.
    private static func numberString(_ d: Double) -> String {
        if d.isFinite && d == d.rounded() && abs(d) < 1e15 {
            return String(Int(d))
        }
        return String(d)
    }

    /// True iff `eventName` equals `step.event` AND every key in `step.match`
    /// is present in `properties` with an equal (stringified) value.
    public static func eventMatchesStep(eventName: String,
                                        properties: [String: Any],
                                        step: TriggerStep) -> Bool {
        guard eventName == step.event else { return false }
        return matches(filter: step.match, against: properties)
    }

    /// True iff every key in `filter` is present in `properties` with an equal
    /// (stringified) value. Empty filter ⇒ always true.
    public static func matches(filter: [String: JSONValue], against properties: [String: Any]) -> Bool {
        for (key, expected) in filter {
            guard let expectedStr = stringify(expected) else { return false }
            guard let actual = properties[key], let actualStr = stringify(actual) else { return false }
            if expectedStr != actualStr { return false }
        }
        return true
    }

    /// Audience check: `audienceMatch ⊆ userProperties` by stringified equality.
    public static func audienceMatches(_ audience: [String: JSONValue],
                                       userProperties: [String: JSONValue]) -> Bool {
        for (key, expected) in audience {
            guard let expectedStr = stringify(expected) else { return false }
            guard let actual = userProperties[key], let actualStr = stringify(actual) else { return false }
            if expectedStr != actualStr { return false }
        }
        return true
    }
}
