//
//  EventCounter.swift
//  MicroSurveysSDK iOS SDK
//
//  Counts tracked events between uploads so the dashboard can show which events
//  the app actually sends, how often, and from which platform ("event signals").
//  Only used when the project turns event signals on (config `eventSignals`).
//
//  What leaves the device: each event name, how many times it fired since the
//  last upload, when it was first and last seen in that window, and up to
//  `maxKeys` property *names*. Never property values, never a user id.
//

import Foundation

struct EventCount: Encodable, Equatable {
    let name: String
    let count: Int
    let firstSeenAt: String
    let lastSeenAt: String
    let propertyKeys: [String]
}

final class EventCounter {

    /// Distinct event names held per upload window; names past this are dropped
    /// until the next upload, so a loop of unique names can't grow memory.
    static let maxNames = 200
    /// Property names kept per event.
    static let maxKeys = 20
    private static let maxNameLength = 200
    private static let maxKeyLength = 100

    private struct Entry {
        var count: Int
        var first: Date
        var last: Date
        var keys: [String]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// First-seen order, so uploads list events in the order they happened.
    private var order: [String] = []

    var size: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func record(name: String, properties: [String: Any] = [:], at now: Date = Date()) {
        guard !name.isEmpty, name.count <= Self.maxNameLength else { return }
        lock.lock(); defer { lock.unlock() }
        var entry: Entry
        if let existing = entries[name] {
            entry = existing
        } else {
            guard entries.count < Self.maxNames else { return }
            entry = Entry(count: 0, first: now, last: now, keys: [])
            order.append(name)
        }
        entry.count += 1
        entry.last = max(entry.last, now)
        for key in properties.keys.sorted() {
            if entry.keys.count >= Self.maxKeys { break }
            if !key.isEmpty, key.count <= Self.maxKeyLength, !entry.keys.contains(key) {
                entry.keys.append(key)
            }
        }
        entries[name] = entry
    }

    /// Everything counted since the last drain, and a fresh window.
    func drain() -> [EventCount] {
        lock.lock()
        let snapshot = entries
        let names = order
        entries = [:]
        order = []
        lock.unlock()
        return names.compactMap { name in
            guard let e = snapshot[name] else { return nil }
            return EventCount(name: name,
                              count: e.count,
                              firstSeenAt: MSTime.string(from: e.first),
                              lastSeenAt: MSTime.string(from: e.last),
                              propertyKeys: e.keys)
        }
    }
}
