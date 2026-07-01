//
//  Models.swift
//  MicroSurveysSDK
//
//  Codable models decoded from the `/api/sdk/config` payload and the answer
//  submission values posted to `/api/sdk/responses`. These mirror the
//  hand-maintained wire contract in `docs/API-CONTRACT.md`.
//
//  This file is intentionally **UIKit-free** so it compiles on every platform
//  the package targets (iOS for the app, macOS for `swift build`/tests). The
//  renderer in the UI layer consumes `Survey` + `Question`.
//

import Foundation

// MARK: - Question type

/// The seven question types supported by the renderer. Raw values match the
/// `QuestionType` enum on the backend (see `prisma/schema.prisma`).
public enum QuestionType: String, Codable, CaseIterable {
    case nps          = "NPS"
    case ces          = "CES"
    case csatStar     = "CSAT_STAR"
    case csatEmoji    = "CSAT_EMOJI"
    case thumbs       = "THUMBS"
    case singleChoice = "SINGLE_CHOICE"
    case openText     = "OPEN_TEXT"
}

// MARK: - Option models

/// One option in a `CSAT_EMOJI` question.
public struct EmojiOption: Codable, Equatable {
    public let value: String
    public let emoji: String
    public let label: String?

    public init(value: String, emoji: String, label: String? = nil) {
        self.value = value
        self.emoji = emoji
        self.label = label
    }
}

/// One option in a `SINGLE_CHOICE` question.
public struct ChoiceOption: Codable, Equatable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

// MARK: - Question config

/// Strongly-typed, per-type decoding of a question's `config` object.
///
/// NPS and CES share the same numeric-scale shape, so they collapse into a
/// single `.scale` case. The owning `Question.type` disambiguates min/max
/// defaults and which answer value shape to submit.
public enum QuestionConfig: Equatable {
    /// `NPS` (0–10) and `CES` (1–7): a numbered scale with optional end labels.
    case scale(min: Int, max: Int, minLabel: String?, maxLabel: String?)
    /// `CSAT_STAR`: a star rating with `count` stars.
    case stars(count: Int)
    /// `CSAT_EMOJI`: an ordered set of emoji options.
    case emoji(options: [EmojiOption])
    /// `THUMBS`: thumbs up / thumbs down (no config).
    case thumbs
    /// `SINGLE_CHOICE`: a vertical list of options.
    case singleChoice(options: [ChoiceOption])
    /// `OPEN_TEXT`: free-form text with an optional placeholder + length cap.
    case openText(placeholder: String?, maxLength: Int?)
}

// MARK: - Question

/// A single survey question. `config` is decoded into a typed `QuestionConfig`
/// based on `type`, applying the contract's documented defaults when a field
/// is omitted.
public struct Question: Codable, Equatable {
    public let id: String
    public let order: Int
    public let type: QuestionType
    public let prompt: String
    /// Whether the user must answer before advancing. JSON key is `required`.
    public let isRequired: Bool
    public let config: QuestionConfig

    public init(id: String,
                order: Int,
                type: QuestionType,
                prompt: String,
                isRequired: Bool,
                config: QuestionConfig) {
        self.id = id
        self.order = order
        self.type = type
        self.prompt = prompt
        self.isRequired = isRequired
        self.config = config
    }

    private enum CodingKeys: String, CodingKey {
        case id, order, type, prompt
        case isRequired = "required"
        case config
    }

    /// Loosely-typed mirror of every key that can appear inside `config`. We
    /// decode this first, then build the typed `QuestionConfig` for the type.
    private struct RawConfig: Decodable {
        let min: Int?
        let max: Int?
        let minLabel: String?
        let maxLabel: String?
        let count: Int?
        let options: [RawOption]?
        let placeholder: String?
        let maxLength: Int?
    }

    private struct RawOption: Decodable {
        let value: String
        let emoji: String?
        let label: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        type = try c.decode(QuestionType.self, forKey: .type)
        prompt = try c.decode(String.self, forKey: .prompt)
        isRequired = try c.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false

        // `config` may be absent (e.g. THUMBS often sends `{}`); treat missing
        // as an empty object so defaults still apply.
        let raw = try c.decodeIfPresent(RawConfig.self, forKey: .config)
        config = Question.buildConfig(type: type, raw: raw)
    }

    public func encode(to encoder: Encoder) throws {
        // Encoding is provided for round-tripping/tests; the SDK only decodes
        // questions in practice.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(order, forKey: .order)
        try c.encode(type, forKey: .type)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(isRequired, forKey: .isRequired)
    }

    private static func buildConfig(type: QuestionType, raw: RawConfig?) -> QuestionConfig {
        switch type {
        case .nps:
            return .scale(min: raw?.min ?? 0, max: raw?.max ?? 10,
                          minLabel: raw?.minLabel, maxLabel: raw?.maxLabel)
        case .ces:
            return .scale(min: raw?.min ?? 1, max: raw?.max ?? 7,
                          minLabel: raw?.minLabel, maxLabel: raw?.maxLabel)
        case .csatStar:
            return .stars(count: raw?.count ?? 5)
        case .csatEmoji:
            let options = (raw?.options ?? []).map {
                EmojiOption(value: $0.value, emoji: $0.emoji ?? "", label: $0.label)
            }
            return .emoji(options: options)
        case .thumbs:
            return .thumbs
        case .singleChoice:
            let options = (raw?.options ?? []).map {
                ChoiceOption(value: $0.value, label: $0.label ?? $0.value)
            }
            return .singleChoice(options: options)
        case .openText:
            return .openText(placeholder: raw?.placeholder, maxLength: raw?.maxLength)
        }
    }
}

// MARK: - Survey

/// A survey as delivered by `/api/sdk/config`. The renderer only requires
/// `id`, `name`, and `questions`; the eligibility/trigger fields are modeled
/// for completeness and decoded leniently (they are not used by the UI).
public struct Survey: Codable, Equatable {
    public let id: String
    public let name: String
    public let questions: [Question]

    // Eligibility metadata (optional; evaluated elsewhere, not by the UI).
    public let audienceMatch: [String: JSONValue]?
    public let samplePercent: Int?
    public let maxPerUserDays: Int?
    /// Kept as raw ISO-8601 strings to avoid imposing a date-decoding strategy
    /// on hosts; parse lazily if/when the trigger engine needs them.
    public let startsAt: String?
    public let endsAt: String?
    public let triggers: [Trigger]?
    /// Whether the respondent may dismiss without answering. `nil` ⇒ treat as dismissible.
    /// When false, the SDK hides the close button and blocks swipe/scrim dismissal.
    public let dismissible: Bool?

    public init(id: String,
                name: String,
                questions: [Question],
                audienceMatch: [String: JSONValue]? = nil,
                samplePercent: Int? = nil,
                maxPerUserDays: Int? = nil,
                startsAt: String? = nil,
                endsAt: String? = nil,
                triggers: [Trigger]? = nil,
                dismissible: Bool? = nil) {
        self.id = id
        self.name = name
        self.questions = questions
        self.audienceMatch = audienceMatch
        self.samplePercent = samplePercent
        self.maxPerUserDays = maxPerUserDays
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.triggers = triggers
        self.dismissible = dismissible
    }

    /// Questions sorted by their declared `order`, which is the order the
    /// renderer presents them in.
    public var orderedQuestions: [Question] {
        questions.sorted { $0.order < $1.order }
    }
}

// MARK: - Triggers (modeled for completeness; not used by the renderer)

public struct Trigger: Codable, Equatable {
    public enum Kind: String, Codable { case single = "SINGLE", sequence = "SEQUENCE" }

    public let id: String
    public let type: Kind
    public let delaySeconds: Int
    public let sequenceWindowSeconds: Int?
    public let fireEvery: Int
    public let warmupCount: Int
    public let steps: [TriggerStep]

    private enum CodingKeys: String, CodingKey {
        case id, type, delaySeconds, sequenceWindowSeconds, fireEvery, warmupCount, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .single
        delaySeconds = try c.decodeIfPresent(Int.self, forKey: .delaySeconds) ?? 0
        sequenceWindowSeconds = try c.decodeIfPresent(Int.self, forKey: .sequenceWindowSeconds)
        fireEvery = try c.decodeIfPresent(Int.self, forKey: .fireEvery) ?? 1
        warmupCount = try c.decodeIfPresent(Int.self, forKey: .warmupCount) ?? 0
        steps = try c.decodeIfPresent([TriggerStep].self, forKey: .steps) ?? []
    }
}

public struct TriggerStep: Codable, Equatable {
    public let order: Int
    public let event: String
    public let match: [String: JSONValue]

    private enum CodingKeys: String, CodingKey { case order, event, match }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        event = try c.decode(String.self, forKey: .event)
        match = try c.decodeIfPresent([String: JSONValue].self, forKey: .match) ?? [:]
    }
}

// MARK: - SDK config envelope

/// Top-level shape of `GET /api/sdk/config`.
public struct SDKConfig: Codable, Equatable {
    public let projectId: String
    public let fetchedAt: String?
    public let surveys: [Survey]
}

// MARK: - Answer submission

/// A single question's answer, encoded to the exact JSON shape the backend
/// expects under `answers[].value`. See the "Answer value shapes" table in
/// `docs/API-CONTRACT.md`.
public enum SurveyAnswerValue: Encodable, Equatable {
    /// `NPS` / `CES` / `CSAT_STAR` → `{ "value": <number> }`
    case number(Int)
    /// `THUMBS` → `{ "value": "up" | "down" }`
    case thumb(Thumb)
    /// `CSAT_EMOJI` → `{ "value": <option value> }`
    case emoji(String)
    /// `SINGLE_CHOICE` → `{ "choice": <option value> }`
    case choice(String)
    /// `OPEN_TEXT` → `{ "text": <string> }`
    case text(String)

    public enum Thumb: String, Encodable { case up, down }

    private enum ValueKey: String, CodingKey { case value }
    private enum ChoiceKey: String, CodingKey { case choice }
    private enum TextKey: String, CodingKey { case text }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .number(let n):
            var c = encoder.container(keyedBy: ValueKey.self)
            try c.encode(n, forKey: .value)
        case .thumb(let t):
            var c = encoder.container(keyedBy: ValueKey.self)
            try c.encode(t.rawValue, forKey: .value)
        case .emoji(let v):
            var c = encoder.container(keyedBy: ValueKey.self)
            try c.encode(v, forKey: .value)
        case .choice(let v):
            var c = encoder.container(keyedBy: ChoiceKey.self)
            try c.encode(v, forKey: .choice)
        case .text(let s):
            var c = encoder.container(keyedBy: TextKey.self)
            try c.encode(s, forKey: .text)
        }
    }
}

/// A `(questionId, value)` pair, encoded as `{ "questionId": ..., "value": {...} }`.
public struct SurveyAnswer: Encodable, Equatable {
    public let questionId: String
    public let value: SurveyAnswerValue

    public init(questionId: String, value: SurveyAnswerValue) {
        self.questionId = questionId
        self.value = value
    }
}

/// The outcome handed back to the host when the survey UI closes.
public struct SurveyResult {
    public let surveyId: String
    /// Answers collected so far, in presentation order. Present even on a
    /// partial (dismissed) survey.
    public let answers: [SurveyAnswer]
    /// `true` if the user advanced through and submitted the final question.
    public let completed: Bool
    /// `true` if the user closed/swiped the survey away before completing.
    public let dismissed: Bool

    public init(surveyId: String, answers: [SurveyAnswer], completed: Bool, dismissed: Bool) {
        self.surveyId = surveyId
        self.answers = answers
        self.completed = completed
        self.dismissed = dismissed
    }
}

// MARK: - JSONValue

/// A minimal, fully-Codable representation of arbitrary JSON. Used for the
/// loosely-typed `match` / `audienceMatch` filters which can hold any JSON
/// scalar or container. Not used by the renderer.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a):  try c.encode(a)
        case .null:          try c.encodeNil()
        }
    }
}
