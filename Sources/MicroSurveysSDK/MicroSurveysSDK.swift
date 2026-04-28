//
//  MicroSurveysSDK.swift
//  MicroSurveysSDK iOS SDK
//
//  Public entry point for the SDK. Callers typically initialize a shared
//  instance early in app launch, then register the Amplitude plugin on
//  their existing Amplitude instance.
//
//  Example:
//      let ms = MicroSurveysSDK(apiKey: "ms_live_xxx")
//      amplitude.add(plugin: ms.amplitudePlugin())
//

import Foundation

public final class MicroSurveysSDK {
    /// MicroSurveysSDK project API key (public key, prefixed `ms_live_` or `ms_test_`).
    public let apiKey: String

    /// Base URL for the MicroSurveysSDK API. Override for self-hosted or staging.
    public let apiBaseURL: URL

    public init(
        apiKey: String,
        apiBaseURL: URL = URL(string: "https://api.microsurveys.io")!
    ) {
        self.apiKey = apiKey
        self.apiBaseURL = apiBaseURL
    }

    /// Manually record an event. Use this when not using Amplitude, or for
    /// events that don't flow through Amplitude's SDK.
    public func trackEvent(_ name: String, properties: [String: Any] = [:]) {
        // TODO: evaluate triggers, show survey if matched
    }
}
