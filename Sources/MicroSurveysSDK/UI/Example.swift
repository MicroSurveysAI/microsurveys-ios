//
//  Example.swift
//  MicroSurveysSDK
//
//  A small, self-contained example of how a host app presents a survey with
//  the renderer. Compiled only in DEBUG so it never ships in release builds.
//  This is reference code, not part of the public API.
//

#if canImport(UIKit) && DEBUG
import UIKit

enum MicroSurveysExample {

    /// Presents the launch **wallet CES** survey (a CES 1–7 effort question)
    /// from `presenter`. In production the `Survey` arrives decoded from the
    /// `/api/sdk/config` response; here we show both decoding from JSON and a
    /// programmatic build.
    static func presentWalletCES(from presenter: UIViewController) {
        // --- Option A: decode the survey straight from the config JSON. -------
        let json = """
        {
          "id": "svy_wallet_ces",
          "name": "Wallet CES",
          "questions": [
            {
              "id": "qst_1",
              "order": 0,
              "type": "CES",
              "prompt": "How easy was it to understand your wallet balance and payment methods?",
              "required": true,
              "config": { "min": 1, "max": 7, "minLabel": "Very difficult", "maxLabel": "Very easy" }
            }
          ]
        }
        """.data(using: .utf8)!

        guard let survey = try? JSONDecoder().decode(Survey.self, from: json) else { return }

        // Optionally brand the renderer by tweaking the default theme.
        var theme = SurveyTheme.default
        // theme.accent = UIColor(red: 0.40, green: 0.31, blue: 0.95, alpha: 1) // your brand

        MicroSurveysUI.present(survey: survey, on: presenter, theme: theme) { result in
            // Hand `result.answers` to the responses uploader. For CES the value
            // encodes as `{ "value": <1...7> }` under `answers[].value`.
            print("Survey completed=\(result.completed) dismissed=\(result.dismissed)")
            for answer in result.answers {
                if let data = try? JSONEncoder().encode(answer),
                   let str = String(data: data, encoding: .utf8) {
                    print("answer:", str) // e.g. {"questionId":"qst_1","value":{"value":6}}
                }
            }
        }
    }

    /// Reference: the full host integration. In production you do NOT present
    /// surveys yourself — you wire up the SDK in ~3 lines and the trigger engine
    /// presents the right survey when a matching Amplitude event flows through.
    ///
    ///     import MicroSurveysSDK
    ///     import AmplitudeSwift
    ///
    ///     let ms = MicroSurveysSDK(apiKey: "ms_live_xxx")   // your project key
    ///     amplitude.add(plugin: ms.amplitudePlugin())        // forward events + identity
    ///     ms.start()                                         // fetch config + flush outbox
    ///
    ///     // Optional — for non-Amplitude hosts or extra audience context:
    ///     ms.setUser(id: "user-123", properties: ["plan": "pro"])
    ///     ms.track("booking_completed", properties: ["amount": 42])
    ///
    /// From here on, when an event satisfies a published survey's trigger and the
    /// user passes window/frequency/audience/sampling/cap eligibility, the SDK
    /// presents the survey on the top-most view controller and POSTs the
    /// impression + response automatically.
    static func runtimeIntegrationSketch() {
        let ms = MicroSurveysSDK(apiKey: "ms_test_demo")
        ms.start()
        // A manual event (the Amplitude plugin path does this for you):
        ms.track("booking_completed", properties: ["amount": 42])
    }

    /// The same survey built programmatically (no JSON), for previews/tests.
    static func presentMultiStepDemo(from presenter: UIViewController) {
        let survey = Survey(
            id: "svy_demo",
            name: "Demo",
            questions: [
                Question(id: "q1", order: 0, type: .ces,
                         prompt: "How easy was it to understand your wallet balance and payment methods?",
                         isRequired: true,
                         config: .scale(min: 1, max: 7, minLabel: "Very difficult", maxLabel: "Very easy")),
                Question(id: "q2", order: 1, type: .openText,
                         prompt: "Anything we could make clearer?",
                         isRequired: false,
                         config: .openText(placeholder: "Optional feedback…", maxLength: 280))
            ]
        )
        MicroSurveysUI.present(survey: survey, on: presenter) { result in
            print("Collected \(result.answers.count) answers, completed=\(result.completed)")
        }
    }
}
#endif
