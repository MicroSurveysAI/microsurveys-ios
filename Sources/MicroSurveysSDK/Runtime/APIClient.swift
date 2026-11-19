//
//  APIClient.swift
//  MicroSurveysSDK
//
//  URLSession-based async client for the SDK endpoints, plus a tiny
//  persistent outbox so impressions/responses survive offline launches. A failed
//  send is retried every few seconds (and on app foreground) until it goes out.
//  Every impression/response carries a UUID `clientId` so the server upserts and
//  retries never duplicate (API-CONTRACT §Idempotency).
//

import Foundation

// MARK: - Errors / results

enum APIError: Error {
    case invalidResponse
    case http(Int)
}

enum ConfigFetchResult {
    case notModified
    /// `rawData` is the original response body, persisted as-is by `ConfigStore`
    /// (a Codable round-trip of `SDKConfig` would be lossy — see `ConfigStore`).
    case config(rawData: Data, config: SDKConfig, theme: ProjectTheme?, etag: String?)
}

// MARK: - Outbox

/// A single queued POST, persisted as its pre-encoded body so we never need to
/// re-derive it (and so `SurveyAnswer`, which is Encodable-only, round-trips as
/// opaque bytes).
private struct OutboxEntry: Codable {
    let id: String       // UUID, used to dedup within the outbox
    let path: String     // e.g. "/api/sdk/impressions"
    let body: Data
}

/// FIFO, disk-backed queue of pending POSTs. Thread-safe.
private final class Outbox {
    private let defaults: UserDefaults
    private let key = "com.microsurveys.outbox"
    private let lock = NSLock()
    private let maxEntries = 200

    init(defaults: UserDefaults) { self.defaults = defaults }

    private func read() -> [OutboxEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([OutboxEntry].self, from: data)
        else { return [] }
        return entries
    }

    private func write(_ entries: [OutboxEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    func enqueue(path: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        var entries = read()
        entries.append(OutboxEntry(id: UUID().uuidString, path: path, body: body))
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        write(entries)
    }

    func snapshot() -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        write(read().filter { $0.id != id })
    }
}

// MARK: - APIClient

final class APIClient {

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let apiVersion = "2026-06-30"
    private let outbox: Outbox

    /// Guards the flush state below.
    private let flushLock = NSLock()
    private var isFlushing = false
    /// `flush()` was called while a flush was running: run another pass before finishing,
    /// so an entry queued after the last check never waits for the next event.
    private var flushRequested = false
    /// Consecutive flushes that stopped on a failure; sets the retry delay.
    private var failedFlushes = 0
    private var retryWork: DispatchWorkItem?

    /// First retry delay after a failed send; doubles per consecutive failure up to `retryMaxDelay`.
    var retryBaseDelay: TimeInterval = 2
    var retryMaxDelay: TimeInterval = 30
    /// Ingest requests give up after this, so a stalled connection can't block the queue.
    static let ingestTimeout: TimeInterval = 15

    init(apiKey: String,
         baseURL: URL,
         session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.outbox = Outbox(defaults: defaults)
    }

    // MARK: Config

    /// `GET /api/sdk/config` with optional `If-None-Match`. Returns `.notModified`
    /// on a 304 so the caller keeps its cache.
    func fetchConfig(etag: String?) async throws -> ConfigFetchResult {
        var request = URLRequest(url: endpoint("/api/sdk/config"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "MS-Api-Version")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        if http.statusCode == 304 {
            MSLog.info("config: 304 Not Modified (using cache)")
            return .notModified
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let config = try JSONDecoder().decode(SDKConfig.self, from: data)
        let theme = (try? JSONDecoder().decode(ThemeEnvelope.self, from: data))?.theme
        let newETag = http.value(forHTTPHeaderField: "ETag")
        MSLog.info("config: fetched \(config.surveys.count) active survey(s): \(config.surveys.map { $0.name })")
        return .config(rawData: data, config: config, theme: theme, etag: newETag)
    }

    // MARK: Impressions / responses

    /// Queues an impression and kicks a flush. Best-effort; never throws. Sent once when the
    /// survey appears (`dismissed: false`), then again with the same `clientId` and
    /// `dismissed: true` if it's closed without an answer; the server flips it.
    func recordImpression(clientId: String,
                          surveyId: String,
                          triggerId: String?,
                          endUserId: String,
                          shownAt: Date,
                          dismissed: Bool,
                          context: DeviceContext) {
        let payload = ImpressionPayload(clientId: clientId,
                                        surveyId: surveyId,
                                        triggerId: triggerId,
                                        endUserId: endUserId,
                                        shownAt: MSTime.string(from: shownAt),
                                        dismissed: dismissed,
                                        context: context)
        MSLog.info("impression queued (survey=\(surveyId), dismissed=\(dismissed))")
        enqueue(path: "/api/sdk/impressions", value: ImpressionBatch(impressions: [payload]))
    }

    /// Queues a response and kicks a flush. Best-effort; never throws.
    func recordResponse(surveyId: String,
                        endUserId: String,
                        completed: Bool,
                        submittedAt: Date,
                        userProps: [String: JSONValue],
                        impressionId: String,
                        triggerId: String?,
                        context: DeviceContext,
                        answers: [SurveyAnswer]) {
        let payload = ResponsePayload(clientId: UUID().uuidString,
                                      surveyId: surveyId,
                                      endUserId: endUserId,
                                      completed: completed,
                                      submittedAt: MSTime.string(from: submittedAt),
                                      userProps: userProps,
                                      impressionId: impressionId,
                                      triggerId: triggerId,
                                      context: context,
                                      answers: answers)
        MSLog.info("response queued (survey=\(surveyId), completed=\(completed), answers=\(answers.count))")
        enqueue(path: "/api/sdk/responses", value: ResponseBatch(responses: [payload]))
    }

    // MARK: Event signals

    /// Queues one upload window of event counts. No clientId: a re-sent batch can
    /// count twice, which is fine for "last seen" and trend lines.
    func recordEventCounts(_ events: [EventCount], context: DeviceContext, sdkVersion: String) {
        guard !events.isEmpty else { return }
        let batch = EventCountsBatch(events: events,
                                     context: .init(platform: context.platform,
                                                    appVersion: context.appVersion,
                                                    osVersion: context.osVersion,
                                                    locale: context.locale,
                                                    sdkVersion: sdkVersion))
        MSLog.info("event counts queued (\(events.count) event name(s))")
        enqueue(path: "/api/sdk/events", value: batch)
    }

    // MARK: Live debugger

    /// Sends one debugger entry from a test device.
    func recordDebug(_ entry: DebugEntry, endUserId: String, context: DeviceContext, sdkVersion: String) {
        let batch = DebugBatch(entries: [entry],
                               endUserId: endUserId,
                               context: .init(platform: context.platform,
                                              appVersion: context.appVersion,
                                              osVersion: context.osVersion,
                                              locale: context.locale,
                                              sdkVersion: sdkVersion))
        enqueue(path: "/api/sdk/debug", value: batch)
    }

    // MARK: Server events

    /// `POST /api/sdk/pending`: takes this user's waiting server events, oldest first.
    /// Not queued: each event is handed out once, and a failed check is simply retried
    /// at the next scheduled one.
    func fetchPendingEvents(userId: String?, deviceId: String?) async throws -> [PendingEvent] {
        var request = URLRequest(url: endpoint("/api/sdk/pending"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "MS-Api-Version")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PendingEventsRequest(userId: userId, deviceId: deviceId))

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        let events = try JSONDecoder().decode(PendingEventsResponse.self, from: data).events
        MSLog.info("pending: \(events.count) server event(s)\(events.isEmpty ? "" : ": \(events.map(\.name))")")
        return events
    }

    private func enqueue<T: Encodable>(path: String, value: T) {
        guard let body = try? JSONEncoder().encode(value) else { return }
        outbox.enqueue(path: path, body: body)
        flush()
    }

    // MARK: Flush

    /// Attempts to POST all queued entries in order. Stops at the first failure
    /// (likely offline), keeps the rest, and retries after a short delay (2s, doubling
    /// to 30s) without waiting for the next event or launch. Entries queued while a
    /// flush is running are sent by the same flush. Successful entries are removed;
    /// idempotency keys make re-sends safe.
    func flush() {
        flushLock.lock()
        if isFlushing { flushRequested = true; flushLock.unlock(); return }
        isFlushing = true
        flushRequested = false
        retryWork?.cancel()
        retryWork = nil
        flushLock.unlock()

        Task {
            // Guards against re-sending an entry whose removal didn't persist.
            var sent = Set<String>()
            var failed = false
            while true {
                drain: while true {
                    let pending = outbox.snapshot().filter { !sent.contains($0.id) }
                    if pending.isEmpty { break }
                    for entry in pending {
                        do {
                            try await post(path: entry.path, body: entry.body)
                            outbox.remove(id: entry.id)
                            sent.insert(entry.id)
                        } catch {
                            failed = true
                            break drain   // network/server problem — retry shortly
                        }
                    }
                }
                if !finishPass(failed: failed) { return }
            }
        }
    }

    /// Ends a flush pass. Returns true when another pass should run because `flush()` was
    /// called meanwhile; otherwise clears the flushing state and, after a failure, schedules a retry.
    private func finishPass(failed: Bool) -> Bool {
        flushLock.lock(); defer { flushLock.unlock() }
        if !failed && flushRequested {
            flushRequested = false
            return true
        }
        isFlushing = false
        flushRequested = false
        if failed {
            failedFlushes += 1
            scheduleRetryLocked()
        } else {
            failedFlushes = 0
        }
        return false
    }

    /// Schedules the next flush after a failure. Caller holds `flushLock`.
    private func scheduleRetryLocked() {
        let delay = min(retryBaseDelay * pow(2, Double(max(failedFlushes - 1, 0))), retryMaxDelay)
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        retryWork?.cancel()
        retryWork = work
        MSLog.info("upload failed; retrying in \(Int(delay))s")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func post(path: String, body: Data) async throws {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.ingestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "MS-Api-Version")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        MSLog.info("POST \(path) -> \(http.statusCode)")
        // 4xx (except 429) are permanent for this body; drop by treating as
        // success so we don't wedge the queue. 429/5xx → throw to retry later.
        if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) || (400..<500).contains(http.statusCode) else {
            throw APIError.http(http.statusCode)
        }
    }

    // MARK: Plumbing

    private func endpoint(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL) ?? baseURL.appendingPathComponent(path)
    }

    /// `URLSession.data(for:)` is iOS 15+, so wrap `dataTask` in a continuation
    /// to keep the iOS 14 deployment target.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: APIError.invalidResponse)
                }
            }
            task.resume()
        }
    }
}
