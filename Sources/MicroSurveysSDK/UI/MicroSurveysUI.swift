//
//  MicroSurveysUI.swift
//  MicroSurveysSDK
//
//  Public entry point for the survey renderer. Given a decoded `Survey`, this
//  presents the native bottom-sheet survey, collects answers, and hands back a
//  `SurveyResult`. The trigger engine / networking layer calls this once a
//  survey is eligible to show; it is intentionally standalone so it can also be
//  driven manually for previews and testing.
//

#if canImport(UIKit)
import UIKit

public enum MicroSurveysUI {

    /// Presents `survey` as a bottom-sheet on `presenter`.
    ///
    /// - Parameters:
    ///   - survey: The decoded survey to render.
    ///   - presenter: The view controller to present from (usually the topmost VC).
    ///   - theme: Visual styling. Defaults to `SurveyTheme.default`; pass a
    ///     customized copy to brand it.
    ///   - animated: Whether to animate the presentation.
    ///   - completion: Called once when the survey closes, with the collected
    ///     answers and whether the user completed or dismissed it.
    /// - Returns: The presented `SurveyViewController`, for advanced callers.
    @discardableResult
    public static func present(survey: Survey,
                               on presenter: UIViewController,
                               theme: SurveyTheme = .default,
                               animated: Bool = true,
                               completion: ((SurveyResult) -> Void)? = nil) -> SurveyViewController {
        let controller = SurveyViewController(survey: survey, theme: theme, completion: completion)
        presenter.present(controller, animated: animated)
        return controller
    }
}
#endif
