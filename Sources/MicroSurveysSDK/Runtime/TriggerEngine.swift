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

final class TriggerEngine {

    /// Supplies the active surveys to evaluate (the cached config's surveys).
    var surveysProvider: () -> [Survey] = { [] }
    /// Supplies the current identity snapshot at evaluation time. The SDK always
    /// has at least an anonymous identity.
    var identityProvider: () -> MSIdentity
    /// Invoked on the **main** queue when a survey should be presented now.
    var onPresent: ((Survey, Trigger, MSIdentity) -> Void)?

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

        for survey in surveysProvider() {
            guard let triggers = survey.triggers, !triggers.isEmpty else { continue }

            for trigger in triggers {
                let satisfied = advance(trigger: trigger,
                                        state: &state,
                                        eventName: name,
                                        properties: properties,
                                        nowDate: nowDate)
                guard satisfied else { continue }

                let occurrence = state.triggers[trigger.id]?.satisfiedCount ?? 0
                MSLog.info("trigger matched for '\(survey.name)' (occurrence \(occurrence)) on event '\(name)'")

                // (1) window
                guard isWithinWindow(survey: survey, nowDate: nowDate) else {
                    MSLog.info("  ✗ skip '\(survey.name)': outside start/end window"); continue
                }
                // (3) frequency
                guard passesFrequency(trigger: trigger, occurrence: occurrence) else {
                    MSLog.info("  ✗ skip '\(survey.name)': frequency (fireEvery=\(trigger.fireEvery), warmup=\(trigger.warmupCount), occ=\(occurrence))")
                    continue
                }
                // (4) audience
                if let audience = survey.audienceMatch,
                   !MatchEvaluator.audienceMatches(audience, userProperties: identity.userProperties) {
                    MSLog.info("  ✗ skip '\(survey.name)': audience mismatch — need \(audience), have user-property keys \(identity.userProperties.keys.sorted())")
                    continue
                }
                // (5) sampling (sticky)
                guard passesSampling(survey: survey, endUserId: endUserId, state: &state) else {
                    MSLog.info("  ✗ skip '\(survey.name)': not in sample (\(survey.samplePercent ?? 100)%)"); continue
                }
                // (6) cap
                guard passesCap(survey: survey, state: state, nowDate: nowDate) else {
                    MSLog.info("  ✗ skip '\(survey.name)': frequency cap (maxPerUserDays=\(survey.maxPerUserDays ?? 0))"); continue
                }

                MSLog.info("  ✓ '\(survey.name)' eligible — showing in \(max(0, trigger.delaySeconds))s")
                scheduleShow(survey: survey, trigger: trigger, identity: identity)
            }
        }

        store.save(endUserId: endUserId, state: state)
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

    private func isWithinWindow(survey: Survey, nowDate: Date) -> Bool {
        if let startsAt = survey.startsAt, let start = MSTime.date(from: startsAt), nowDate < start {
            return false
        }
        if let endsAt = survey.endsAt, let end = MSTime.date(from: endsAt), nowDate > end {
            return false
        }
        return true
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
