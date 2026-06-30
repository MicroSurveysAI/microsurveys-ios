//
//  TriggerSequencer.swift
//  MicroSurveysSDK
//
//  Pure state-machine for advancing a trigger's SINGLE/SEQUENCE progress on an
//  incoming event. Separated from the engine (no queues, no clock, no storage)
//  so the sequence + window ordering rules are unit-testable cross-platform.
//

import Foundation

enum TriggerSequencer {

    /// Advances `record` for one event.
    ///
    /// - Returns: the updated record and whether the trigger's full condition is
    ///   now satisfied. On satisfaction the record's `satisfiedCount` is bumped
    ///   and its sequence progress reset.
    static func advance(trigger: Trigger,
                        record: TriggerRecord,
                        eventName: String,
                        properties: [String: Any],
                        nowT: TimeInterval) -> (TriggerRecord, Bool) {

        var record = record
        let steps = trigger.steps.sorted { $0.order < $1.order }
        guard !steps.isEmpty else { return (record, false) }

        func matchesStep(_ index: Int) -> Bool {
            MatchEvaluator.eventMatchesStep(eventName: eventName, properties: properties, step: steps[index])
        }

        var satisfied = false

        switch trigger.type {
        case .single:
            // One step (the first); matching it satisfies the condition.
            satisfied = matchesStep(0)

        case .sequence:
            let expected = min(record.stepIndex, steps.count - 1)

            if matchesStep(expected) {
                if expected == 0 {
                    record.startedAt = nowT
                    record.stepIndex = 1
                } else if windowExpired(window: trigger.sequenceWindowSeconds,
                                        startedAt: record.startedAt, nowT: nowT) {
                    // The sequence window lapsed; restart, re-checking step 0.
                    if matchesStep(0) {
                        record.startedAt = nowT
                        record.stepIndex = 1
                    } else {
                        record.stepIndex = 0
                        record.startedAt = nil
                    }
                } else {
                    record.stepIndex = expected + 1
                }

                if record.stepIndex >= steps.count {
                    satisfied = true
                    record.stepIndex = 0
                    record.startedAt = nil
                }
            } else if expected != 0 && matchesStep(0) {
                // Out-of-order event that *is* step 0 — restart the sequence.
                record.startedAt = nowT
                record.stepIndex = 1
                if steps.count == 1 {
                    satisfied = true
                    record.stepIndex = 0
                    record.startedAt = nil
                }
            }
        }

        if satisfied { record.satisfiedCount += 1 }
        return (record, satisfied)
    }

    static func windowExpired(window: Int?, startedAt: TimeInterval?, nowT: TimeInterval) -> Bool {
        guard let window, window > 0, let startedAt else { return false }
        return (nowT - startedAt) > Double(window)
    }
}
