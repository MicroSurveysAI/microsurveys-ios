//
//  ServerEvents.swift
//  MicroSurveysSDK
//
//  The server-events mailbox (API-CONTRACT §6). Events the app's backend sends
//  to Amplitude never pass through the app; they wait on the server for this
//  user instead. While config has `pendingEvents: true` the SDK checks for them:
//
//    • when the app starts (config loaded) and on every foreground,
//    • 30 s and 90 s after that (Amplitude streams within about a minute),
//    • every 5 minutes while in the foreground,
//    • every minute while a sequence waits on a server event as its next step
//      (for up to 3 hours after the sequence started).
//
//  Timers stop in the background. One check runs at a time; a failed check is
//  just retried by the next one. Each returned event is replayed through the
//  trigger engine at the time it happened (see `MicroSurveysSDK.replay`).
//

import Foundation

final class ServerEventsMailbox {

    /// Whether config has `pendingEvents: true`.
    var isEnabled: () -> Bool = { false }
    /// Whether a sequence for the current user waits on a server event.
    var isWaiting: () -> Bool = { false }
    /// The ids the server matches events on: Amplitude user id (or the host's
    /// `setUser` id) and Amplitude device id.
    var ids: () -> (userId: String?, deviceId: String?) = { (nil, nil) }
    /// Takes this user's waiting events from the server, oldest first.
    var fetch: (_ userId: String?, _ deviceId: String?) async throws -> [PendingEvent] = { _, _ in [] }
    /// Feeds one page of events into the trigger engine.
    var replay: ([PendingEvent]) -> Void = { _ in }

    static let followUpDelays: [TimeInterval] = [30, 90]
    static let foregroundInterval: TimeInterval = 5 * 60
    static let waitingInterval: TimeInterval = 60
    /// The server's page size: a full page means more may be waiting.
    static let pageSize = 50

    // Main-queue state.
    private var started = false
    private var active = false
    private var timers: [Timer] = []

    private let lock = NSLock()
    private var inFlight = false

    deinit {
        timers.forEach { $0.invalidate() }
    }

    // MARK: Lifecycle

    /// Called by `MicroSurveysSDK.start()`: foregrounds before it don't check.
    func start() {
        onMain { [weak self] in
            self?.started = true
            self?.resume()
        }
    }

    /// Checks now and schedules the follow-ups and periodic checks for this
    /// foreground. No-op before `start()`, while already running, or when the
    /// project has no server events.
    func resume() {
        onMain { [weak self] in
            guard let self, self.started, !self.active, self.isEnabled() else { return }
            self.active = true
            self.check()
            for delay in Self.followUpDelays {
                self.schedule(after: delay, repeats: false) { $0.check() }
            }
            self.schedule(after: Self.foregroundInterval, repeats: true) { $0.check() }
            self.schedule(after: Self.waitingInterval, repeats: true) { mailbox in
                if mailbox.isWaiting() { mailbox.check() }
            }
        }
    }

    /// Stops every timer (the app went to the background).
    func pause() {
        onMain { [weak self] in
            guard let self else { return }
            self.active = false
            self.timers.forEach { $0.invalidate() }
            self.timers.removeAll()
        }
    }

    // MARK: Check

    /// One mailbox check, plus one more when a full page came back. Skipped when
    /// the project has no server events, when there's no id to ask with, or while
    /// another check is in flight.
    func check() {
        guard isEnabled() else { return }
        let (userId, deviceId) = ids()
        guard userId != nil || deviceId != nil else { return }

        guard setInFlight(true) else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { _ = self.setInFlight(false) }
            do {
                let events = try await self.fetch(userId, deviceId)
                self.replay(events)
                if events.count == Self.pageSize {
                    self.replay(try await self.fetch(userId, deviceId))
                }
            } catch {
                MSLog.info("pending events check failed (\(error)); retrying at the next check")
            }
        }
    }

    // MARK: Plumbing

    /// Sets `inFlight`; returns false when starting a check while one is running.
    private func setInFlight(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value && inFlight { return false }
        inFlight = value
        return true
    }

    private func schedule(after interval: TimeInterval, repeats: Bool,
                          _ action: @escaping (ServerEventsMailbox) -> Void) {
        timers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { [weak self] _ in
            guard let self else { return }
            action(self)
        })
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

extension PendingEvent {
    /// `events` in `occurredAt` order (ties keep server order), each with its
    /// event time. An unreadable `occurredAt` counts as `fallback`.
    static func replayOrder(_ events: [PendingEvent], fallback: Date) -> [(event: PendingEvent, at: Date)] {
        events.enumerated()
            .map { (index: $0.offset, event: $0.element, at: $0.element.occurredDate ?? fallback) }
            .sorted { $0.at != $1.at ? $0.at < $1.at : $0.index < $1.index }
            .map { (event: $0.event, at: $0.at) }
    }
}
