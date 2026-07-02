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

    /// Verbose by default in DEBUG builds only; OFF in release so end-user event
    /// properties (potential PII) are never written to the device console in shipped
    /// apps. Integrators can still opt in via `MicroSurveysSDK.loggingEnabled = true`.
    #if DEBUG
    static var level: Level = .debug
    #else
    static var level: Level = .off
    #endif

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
