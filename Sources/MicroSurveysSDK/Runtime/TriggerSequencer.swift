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

    /// Advances `record` for one event. `nowT` is when the event happened: the
    /// current time for a live event, `occurredAt` for a replayed server event.
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

            // An event from before this sequence started (a late-arriving server
            // event) can't continue it, and doesn't reset it either.
            if expected != 0, let startedAt = record.startedAt, nowT < startedAt {
                return (record, false)
            }

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

    /// How long after a sequence starts the SDK keeps checking the mailbox often
    /// for its next step (see `waitsOnServerEvent`).
    static let serverEventWaitLimit: TimeInterval = 3 * 60 * 60

    /// Whether `trigger` is a sequence that has started (step 1+ reached) and whose
    /// next step is an event in `serverEvents`, started less than
    /// `serverEventWaitLimit` ago. While any trigger waits like this, the SDK checks
    /// the server-events mailbox every minute.
    static func waitsOnServerEvent(trigger: Trigger,
                                   record: TriggerRecord?,
                                   serverEvents: Set<String>,
                                   nowT: TimeInterval) -> Bool {
        guard trigger.type == .sequence,
              let record, record.stepIndex > 0, let startedAt = record.startedAt,
              nowT - startedAt < serverEventWaitLimit else { return false }
        let steps = trigger.steps.sorted { $0.order < $1.order }
        guard record.stepIndex < steps.count else { return false }
        return serverEvents.contains(steps[record.stepIndex].event)
    }

    static func windowExpired(window: Int?, startedAt: TimeInterval?, nowT: TimeInterval) -> Bool {
        guard let window, window > 0, let startedAt else { return false }
        return (nowT - startedAt) > Double(window)
    }
}
