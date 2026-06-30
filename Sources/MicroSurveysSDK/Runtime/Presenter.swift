//
//  Presenter.swift
//  MicroSurveysSDK
//
//  Finds the top-most view controller and presents an eligible survey via
//  `MicroSurveysUI.present(...)`. Maps the project's `ProjectTheme` (from the
//  config payload) onto a `SurveyTheme`, falling back to `.default`. Hosts can
//  override where surveys anchor via `presentationAnchor`.
//
//  UIKit-only; the engine/networking layers don't depend on it.
//

#if canImport(UIKit)
import UIKit

final class Presenter {

    /// Optional host override: return the VC surveys should present from.
    var presentationAnchor: (() -> UIViewController?)?

    /// Theme applied to presented surveys; set from the fetched project theme.
    var theme: SurveyTheme = .default

    /// Presents `survey` from the top-most (or host-provided) VC. Returns the
    /// `SurveyResult` (or `nil` if no anchor was available). Must be called on
    /// the main thread.
    @discardableResult
    func present(survey: Survey, completion: @escaping (SurveyResult?) -> Void) -> Bool {
        guard let anchor = presentationAnchor?() ?? Presenter.topViewController() else {
            completion(nil)
            return false
        }
        MicroSurveysUI.present(survey: survey, on: anchor, theme: theme) { result in
            completion(result)
        }
        return true
    }

    // MARK: Top view controller

    /// Walks from the active foreground scene's key window down through any
    /// presented controllers to find the front-most VC.
    static func topViewController() -> UIViewController? {
        guard let root = keyWindow()?.rootViewController else { return nil }
        return topMost(of: root)
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }

        // Prefer the foreground-active scene's key window.
        if let active = scenes.first(where: { $0.activationState == .foregroundActive }) {
            if let key = active.windows.first(where: { $0.isKeyWindow }) ?? active.windows.first {
                return key
            }
        }
        // Fall back to any scene's key window.
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
                return key
            }
        }
        return nil
    }

    private static func topMost(of controller: UIViewController) -> UIViewController {
        if let presented = controller.presentedViewController {
            return topMost(of: presented)
        }
        if let nav = controller as? UINavigationController, let top = nav.visibleViewController {
            return topMost(of: top)
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            return topMost(of: selected)
        }
        return controller
    }
}

// MARK: - Theme mapping

extension Presenter {

    /// Best-effort map of the project theme onto a `SurveyTheme`, starting from
    /// `.default` and overriding only the keys provided.
    ///
    /// - TODO: `position == "center"` is not honored — the MVP renderer is
    ///   bottom-sheet only. `font` (a host-bundled family) is likewise not yet
    ///   resolved; only `"system"` is supported today.
    static func makeTheme(from project: ProjectTheme?) -> SurveyTheme {
        var theme = SurveyTheme.default
        guard let project else { return theme }

        if let c = UIColor(msHex: project.accent)        { theme.accent = c }
        if let c = UIColor(msHex: project.accentText)    { theme.accentText = c }
        if let c = UIColor(msHex: project.background)    { theme.background = c }
        if let c = UIColor(msHex: project.surface)       { theme.surface = c }
        if let c = UIColor(msHex: project.text)          { theme.text = c }
        if let c = UIColor(msHex: project.secondaryText) { theme.secondaryText = c }
        if let c = UIColor(msHex: project.border)        { theme.border = c }
        if let radius = project.cornerRadius {
            theme.cornerRadius = CGFloat(radius)
            // Keep control radius proportional but a touch tighter than the card.
            theme.controlCornerRadius = CGFloat(max(0, radius - 2))
        }
        return theme
    }
}

extension UIColor {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (with or without the leading `#`).
    /// Returns `nil` for empty/invalid input so callers keep their default.
    convenience init?(msHex hex: String?) {
        guard var hex = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }

        // Expand shorthand #RGB → #RRGGBB.
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
#endif
