//
//  APIClient.swift
//  MicroSurveysSDK
//
//  URLSession-based async client for the three SDK endpoints, plus a tiny
//  persistent outbox so impressions/responses survive offline launches and
//  flush on the next start. Every impression/response carries a UUID `clientId`
//  so the server upserts and retries never duplicate (API-CONTRACT §Idempotency).
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

    /// Guards against concurrent flushes.
    private let flushLock = NSLock()
    private var isFlushing = false

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

        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }

        let config = try JSONDecoder().decode(SDKConfig.self, from: data)
        let theme = (try? JSONDecoder().decode(ThemeEnvelope.self, from: data))?.theme
        let newETag = http.value(forHTTPHeaderField: "ETag")
        return .config(rawData: data, config: config, theme: theme, etag: newETag)
    }

    // MARK: Impressions / responses

    /// Queues an impression and kicks a flush. Best-effort; never throws.
    func recordImpression(surveyId: String,
                          triggerId: String?,
                          endUserId: String,
                          shownAt: Date,
                          dismissed: Bool) {
        let payload = ImpressionPayload(clientId: UUID().uuidString,
                                        surveyId: surveyId,
                                        triggerId: triggerId,
                                        endUserId: endUserId,
                                        shownAt: MSTime.string(from: shownAt),
                                        dismissed: dismissed)
        enqueue(path: "/api/sdk/impressions", value: ImpressionBatch(impressions: [payload]))
    }

    /// Queues a response and kicks a flush. Best-effort; never throws.
    func recordResponse(surveyId: String,
                        endUserId: String,
                        completed: Bool,
                        submittedAt: Date,
                        userProps: [String: JSONValue],
                        answers: [SurveyAnswer]) {
        let payload = ResponsePayload(clientId: UUID().uuidString,
                                      surveyId: surveyId,
                                      endUserId: endUserId,
                                      completed: completed,
                                      submittedAt: MSTime.string(from: submittedAt),
                                      userProps: userProps,
                                      answers: answers)
        enqueue(path: "/api/sdk/responses", value: ResponseBatch(responses: [payload]))
    }

    private func enqueue<T: Encodable>(path: String, value: T) {
        guard let body = try? JSONEncoder().encode(value) else { return }
        outbox.enqueue(path: path, body: body)
        flush()
    }

    // MARK: Flush

    /// Attempts to POST all queued entries in order. Stops at the first failure
    /// (likely offline) and leaves the rest for next time. Successful entries
    /// are removed; idempotency keys make re-sends safe.
    func flush() {
        flushLock.lock()
        if isFlushing { flushLock.unlock(); return }
        isFlushing = true
        flushLock.unlock()

        Task {
            defer {
                flushLock.lock(); isFlushing = false; flushLock.unlock()
            }
            for entry in outbox.snapshot() {
                do {
                    try await post(path: entry.path, body: entry.body)
                    outbox.remove(id: entry.id)
                } catch {
                    break   // network/server problem — retry on the next flush
                }
            }
        }
    }

    private func post(path: String, body: Data) async throws {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiVersion, forHTTPHeaderField: "MS-Api-Version")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
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
