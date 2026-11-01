//
//  TriggerEngine.swift
//  MicroSurveysSDK
//
//  The evaluator. For each incoming event it advances every active survey's
//  trigger state, and when a trigger's full condition is satisfied it walks the
//  eligibility order from API-CONTRACT §Eligibility:
//
//    1. window (startsAt/endsAt)   2. trigger condition (advanced here)
//    3. frequency (warmupCount + fireEvery)
//    4. audience (audienceMatch ⊆ user properties)
//    5. sampling (deterministic, sticky)   6. per-user cap (maxPerUserDays)
//
//  Eligible surveys are scheduled after `delaySeconds`; the cap is re-checked at
//  fire time. Evaluation runs on a serial queue off the main thread; the
//  presentation callback is dispatched to main.
//

import Foundation

/// Why the engine did or didn't schedule a survey for an event. Reported to the
/// live debugger for test devices; never affects what the engine does. Raw
/// values match the web and React Native SDKs.
enum DecisionReason: String, Encodable {
    case platform
    case propertyMismatch = "property_mismatch"
    case sequenceInProgress = "sequence_in_progress"
    case notStarted = "not_started"
    case ended
    case frequency
    case audience
    case sampledOut = "sampled_out"
    case cap
    case eligible
    case shown
    case anotherSurveyShowing = "another_survey_showing"
    /// iOS only: no view controller to present from.
    case notPresentable = "not_presentable"
}

struct Decision: Encodable, Equatable {
    let surveyId: String
    let triggerId: String?
    let reason: DecisionReason
    /// For `eligible`: seconds until the survey shows.
    var delaySeconds: Int? = nil
}

final class TriggerEngine {

    /// Supplies the active surveys to evaluate (the cached config's surveys).
    var surveysProvider: () -> [Survey] = { [] }
    /// Supplies the current identity snapshot at evaluation time. The SDK always
    /// has at least an anonymous identity.
    var identityProvider: () -> MSIdentity
    /// Invoked on the **main** queue when a survey should be presented now.
    var onPresent: ((Survey, Trigger, MSIdentity) -> Void)?
    /// Invoked on the engine queue after each event with every decision about a
    /// survey whose trigger names it (empty when none does). For the live debugger.
    var onEvaluated: ((String, [String: Any], [Decision]) -> Void)?
    /// Invoked on the engine queue for a decision made after the event, when a
    /// delayed survey's cap is re-checked.
    var onLateDecision: ((Decision) -> Void)?

    private let store: TriggerStateStore
    private let queue = DispatchQueue(label: "com.microsurveys.engine")
    /// Injectable clock for deterministic tests.
    private let now: () -> Date

    init(store: TriggerStateStore,
         identityProvider: @escaping () -> MSIdentity,
         now: @escaping () -> Date = Date.init) {
        self.store = store
        self.identityProvider = identityProvider
        self.now = now
    }

    // MARK: Entry point

    /// Feed an event into the engine. Returns immediately; evaluation is async.
    func process(name: String, properties: [String: Any]) {
        queue.async { [weak self] in
            self?.evaluate(name: name, properties: properties)
        }
    }

    // MARK: Evaluation

    private func evaluate(name: String, properties: [String: Any]) {
        let identity = identityProvider()
        let endUserId = identity.endUserId
        var state = store.load(endUserId: endUserId)
        let nowDate = now()
        var decisions: [Decision] = []

        for survey in surveysProvider() {
            guard let triggers = survey.triggers, !triggers.isEmpty else { continue }
            // Only surveys whose trigger names this event are reported to the debugger.
            let names: (Trigger) -> Bool = { $0.steps.contains { $0.event == name } }

            // Platform targeting: skip when the list is non-empty and excludes iOS.
            if let platforms = survey.platforms, !platforms.isEmpty, !platforms.contains("ios") {
                if let t = triggers.first(where: names) {
                    decisions.append(Decision(surveyId: survey.id, triggerId: t.id, reason: .platform))
                }
                MSLog.info("  ✗ skip '\(survey.name)': platform-targeted \(platforms), not iOS"); continue
            }

            for trigger in triggers {
                let satisfied = advance(trigger: trigger,
                                        state: &state,
                                        eventName: name,
                                        properties: properties,
                                        nowDate: nowDate)
                let skip: (DecisionReason) -> Void = {
                    decisions.append(Decision(surveyId: survey.id, triggerId: trigger.id, reason: $0))
                }
                guard satisfied else {
                    if names(trigger) {
                        // Matched a step without completing the trigger (a sequence), or had the
                        // right name with the wrong properties.
                        let matchedStep = trigger.steps.contains {
                            MatchEvaluator.eventMatchesStep(eventName: name, properties: properties, step: $0)
                        }
                        skip(matchedStep ? .sequenceInProgress : .propertyMismatch)
                    }
                    continue
                }

                let occurrence = state.triggers[trigger.id]?.satisfiedCount ?? 0
                MSLog.info("trigger matched for '\(survey.name)' (occurrence \(occurrence)) on event '\(name)'")

                // (1) window
                if let outside = windowReason(survey: survey, nowDate: nowDate) {
                    skip(outside)
                    MSLog.info("  ✗ skip '\(survey.name)': outside start/end window"); continue
                }
                // (3) frequency
                guard passesFrequency(trigger: trigger, occurrence: occurrence) else {
                    skip(.frequency)
                    MSLog.info("  ✗ skip '\(survey.name)': frequency (fireEvery=\(trigger.fireEvery), warmup=\(trigger.warmupCount), occ=\(occurrence))")
                    continue
                }
                // (4) audience
                if let audience = survey.audienceMatch,
                   !MatchEvaluator.audienceMatches(audience, userProperties: identity.userProperties) {
                    skip(.audience)
                    MSLog.info("  ✗ skip '\(survey.name)': audience mismatch — need \(audience), have user-property keys \(identity.userProperties.keys.sorted())")
                    continue
                }
                // (5) sampling (sticky)
                guard passesSampling(survey: survey, endUserId: endUserId, state: &state) else {
                    skip(.sampledOut)
                    MSLog.info("  ✗ skip '\(survey.name)': not in sample (\(survey.samplePercent ?? 100)%)"); continue
                }
                // (6) cap
                guard passesCap(survey: survey, state: state, nowDate: nowDate) else {
                    skip(.cap)
                    MSLog.info("  ✗ skip '\(survey.name)': frequency cap (maxPerUserDays=\(survey.maxPerUserDays ?? 0))"); continue
                }

                decisions.append(Decision(surveyId: survey.id, triggerId: trigger.id, reason: .eligible,
                                          delaySeconds: max(0, trigger.delaySeconds)))
                MSLog.info("  ✓ '\(survey.name)' eligible — showing in \(max(0, trigger.delaySeconds))s")
                scheduleShow(survey: survey, trigger: trigger, identity: identity)
            }
        }

        store.save(endUserId: endUserId, state: state)
        onEvaluated?(name, properties, decisions)
    }

    // MARK: Trigger advancement

    /// Advances `trigger`'s sequence/single state for this event, returning
    /// `true` (and bumping `satisfiedCount`) when the full condition is met.
    private func advance(trigger: Trigger,
                         state: inout UserTriggerState,
                         eventName: String,
                         properties: [String: Any],
                         nowDate: Date) -> Bool {
        let record = state.triggers[trigger.id] ?? TriggerRecord()
        let (updated, satisfied) = TriggerSequencer.advance(trigger: trigger,
                                                            record: record,
                                                            eventName: eventName,
                                                            properties: properties,
                                                            nowT: nowDate.timeIntervalSince1970)
        state.triggers[trigger.id] = updated
        return satisfied
    }

    // MARK: Eligibility checks

    /// `nil` inside the start/end window, otherwise which side of it we're on.
    private func windowReason(survey: Survey, nowDate: Date) -> DecisionReason? {
        if let startsAt = survey.startsAt, let start = MSTime.date(from: startsAt), nowDate < start {
            return .notStarted
        }
        if let endsAt = survey.endsAt, let end = MSTime.date(from: endsAt), nowDate > end {
            return .ended
        }
        return nil
    }

    /// `occurrence` is 1-based. Ignore the first `warmupCount`, then fire on
    /// every `fireEvery`-th satisfied occurrence thereafter.
    private func passesFrequency(trigger: Trigger, occurrence: Int) -> Bool {
        let fireEvery = max(1, trigger.fireEvery)
        let effective = occurrence - trigger.warmupCount
        return effective >= 1 && effective % fireEvery == 0
    }

    private func passesSampling(survey: Survey, endUserId: String, state: inout UserTriggerState) -> Bool {
        if let decision = state.surveys[survey.id]?.sampleDecision { return decision }
        let decision = Sampling.inSample(endUserId: endUserId,
                                         surveyId: survey.id,
                                         samplePercent: survey.samplePercent ?? 100)
        var record = state.surveys[survey.id] ?? SurveyRecord()
        record.sampleDecision = decision
        state.surveys[survey.id] = record
        return decision
    }

    private func passesCap(survey: Survey, state: UserTriggerState, nowDate: Date) -> Bool {
        let days = survey.maxPerUserDays ?? 0
        guard days > 0, let lastShown = state.surveys[survey.id]?.lastShownAt else { return true }
        let elapsed = nowDate.timeIntervalSince1970 - lastShown
        return elapsed >= Double(days) * 86_400
    }

    // MARK: Scheduling

    private func scheduleShow(survey: Survey, trigger: Trigger, identity: MSIdentity) {
        let delay = max(0, trigger.delaySeconds)
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self else { return }
            let endUserId = identity.endUserId
            var state = self.store.load(endUserId: endUserId)
            let nowDate = self.now()

            // Re-check the cap at fire time (another survey may have shown during
            // the delay).
            guard self.passesCap(survey: survey, state: state, nowDate: nowDate) else {
                self.onLateDecision?(Decision(surveyId: survey.id, triggerId: trigger.id, reason: .cap))
                MSLog.info("  ✗ '\(survey.name)' suppressed at fire time: cap")
                return
            }

            // Record the show now so the cap holds even before the impression
            // round-trips.
            var record = state.surveys[survey.id] ?? SurveyRecord()
            record.lastShownAt = nowDate.timeIntervalSince1970
            state.surveys[survey.id] = record
            self.store.save(endUserId: endUserId, state: state)

            DispatchQueue.main.async {
                self.onPresent?(survey, trigger, identity)
            }
        }
    }
}
