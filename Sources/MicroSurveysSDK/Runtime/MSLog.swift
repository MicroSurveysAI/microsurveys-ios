//
//  MSLog.swift
//  MicroSurveysSDK
//
//  Lightweight console logger. Enabled by default in DEBUG builds and silent in
//  release, so integrators see exactly what the SDK is doing (events received,
//  trigger decisions, presentation, network) in the Xcode console — filter by
//  "[MicroSurveys]". Toggle via `MicroSurveysSDK.loggingEnabled`.
//

import Foundation

enum MSLog {
    enum Level: Int { case off = 0, info = 1, debug = 2 }

    /// On by default so integration logs show without extra setup (this SDK is pre-launch).
    /// `#if DEBUG` is unreliable for SwiftPM targets, so we don't gate on it — turn off in
    /// production via `MicroSurveysSDK.loggingEnabled = false`.
    static var level: Level = .debug

    /// High-signal lines: lifecycle, trigger decisions, presentation, network.
    static func info(_ message: @autoclosure () -> String) { emit(.info, message()) }

    /// Verbose lines: every event flowing through the engine, identity updates.
    static func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }

    private static func emit(_ threshold: Level, _ message: @autoclosure () -> String) {
        guard level.rawValue >= threshold.rawValue else { return }
        // NSLog (not print) so lines reliably surface in the Xcode console and Console.app.
        NSLog("[MicroSurveys] %@", message())
    }
}
