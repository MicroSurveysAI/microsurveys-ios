//
//  SurveyTheme.swift
//  MicroSurveysSDK
//
//  The single source of truth for the survey UI's look & feel. Everything the
//  renderer draws pulls colors, fonts, spacing, and corner radii from here, so
//  restyling to the final Figma design is a matter of editing/overriding one
//  `SurveyTheme` value — no view code needs to change.
//
//  Aesthetic: Untitled-UI / shadcn — neutral grays, generous spacing, rounded
//  corners, subtle shadows, system font, one overridable accent (indigo/violet).
//  Fully light/dark-mode aware via dynamic `UIColor`s.
//

#if canImport(UIKit)
import UIKit

/// Where the survey card sits on screen.
public enum SurveyPosition { case bottom, center }

public struct SurveyTheme {

    // MARK: Colors

    /// Page/scrim color behind the card (used by the iOS 14 fallback dim view).
    public var background: UIColor
    /// The card's fill color.
    public var surface: UIColor
    /// Primary text (prompts, chip numbers when unselected, choice labels).
    public var text: UIColor
    /// De-emphasized text (progress, end labels, placeholders, counters).
    public var secondaryText: UIColor
    /// The one brand color: selected chips, primary button, focus rings.
    public var accent: UIColor
    /// Foreground drawn on top of `accent` (e.g. primary button title).
    public var accentText: UIColor
    /// Hairline borders around chips, choices, text fields, the card edge.
    public var border: UIColor
    /// Neutral fill for unselected controls / scale "track".
    public var track: UIColor

    // MARK: Metrics

    /// Corner radius for the card and large surfaces (~16pt).
    public var cornerRadius: CGFloat
    /// Corner radius for chips, choice rows, the primary button (~12pt).
    public var controlCornerRadius: CGFloat
    /// Base spacing unit; the layout derives its rhythm from this.
    public var spacing: CGFloat
    /// Height of tappable controls (chips, button, choice rows).
    public var controlHeight: CGFloat

    // MARK: Fonts

    public var promptFont: UIFont
    public var bodyFont: UIFont
    public var captionFont: UIFont
    public var buttonFont: UIFont
    public var chipFont: UIFont

    // MARK: Shadow

    /// Subtle elevation under the card. Set `shadowOpacity` to 0 to disable.
    public var shadowColor: UIColor
    public var shadowOpacity: Float
    public var shadowRadius: CGFloat
    public var shadowOffset: CGSize

    // MARK: Layout

    /// Where the survey card is anchored on screen.
    public var position: SurveyPosition
    /// Text alignment for prompts and labels (`.natural` = leading).
    public var alignment: NSTextAlignment
    /// When true (default), a bottom sheet keeps the system's device-native corner radius (which
    /// matches the hardware's screen corners). Set false to override with `cornerRadius`.
    public var useNativeSheetCorners: Bool

    public init(background: UIColor,
                surface: UIColor,
                text: UIColor,
                secondaryText: UIColor,
                accent: UIColor,
                accentText: UIColor,
                border: UIColor,
                track: UIColor,
                cornerRadius: CGFloat = 16,
                controlCornerRadius: CGFloat = 12,
                spacing: CGFloat = 16,
                controlHeight: CGFloat = 48,
                promptFont: UIFont = SurveyTheme.scaledFont(20, .semibold, .title3),
                bodyFont: UIFont = SurveyTheme.scaledFont(16, .regular, .body),
                captionFont: UIFont = SurveyTheme.scaledFont(13, .regular, .footnote),
                buttonFont: UIFont = SurveyTheme.scaledFont(16, .semibold, .headline),
                chipFont: UIFont = SurveyTheme.scaledFont(16, .medium, .body),
                shadowColor: UIColor = .black,
                shadowOpacity: Float = 0.18,
                shadowRadius: CGFloat = 24,
                shadowOffset: CGSize = CGSize(width: 0, height: -4),
                position: SurveyPosition = .bottom,
                alignment: NSTextAlignment = .natural,
                useNativeSheetCorners: Bool = true) {
        self.background = background
        self.surface = surface
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.accentText = accentText
        self.border = border
        self.track = track
        self.cornerRadius = cornerRadius
        self.controlCornerRadius = controlCornerRadius
        self.spacing = spacing
        self.controlHeight = controlHeight
        self.promptFont = promptFont
        self.bodyFont = bodyFont
        self.captionFont = captionFont
        self.buttonFont = buttonFont
        self.chipFont = chipFont
        self.shadowColor = shadowColor
        self.shadowOpacity = shadowOpacity
        self.shadowRadius = shadowRadius
        self.shadowOffset = shadowOffset
        self.position = position
        self.alignment = alignment
        self.useNativeSheetCorners = useNativeSheetCorners
    }

    /// Rebuild the fonts from a font family (keeps sizes + Dynamic Type), selecting the right weight
    /// per role. The family is registered at runtime by `GoogleFontLoader` (fetched from Google Fonts,
    /// in memory) or may be one the host app bundled itself. If it isn't registered yet, the system
    /// font is kept and the SDK re-applies the theme once the fetch completes. For an exact custom
    /// face, set the individual `*Font` fields directly instead.
    public mutating func applyFontFamily(_ family: String) {
        // No registered faces for this family yet (still fetching, or unknown) → keep system fonts.
        guard !UIFont.fontNames(forFamilyName: family).isEmpty else {
            MSLog.debug("theme font '\(family)' not yet registered — using system font for now")
            return
        }

        func f(_ size: CGFloat, _ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
            let base = UIFont(descriptor: descriptor, size: size)
            return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        }
        promptFont = f(20, .title3, .semibold)
        bodyFont = f(16, .body, .regular)
        captionFont = f(13, .footnote, .regular)
        buttonFont = f(16, .headline, .semibold)
        chipFont = f(16, .body, .medium)
    }

    // MARK: Default theme

    /// A clean, modern, dark-mode-aware default. Copy and tweak the accent (or
    /// any field) to brand it:
    ///
    ///     var theme = SurveyTheme.default
    ///     theme.accent = UIColor(named: "BrandPurple")!
    ///
    public static var `default`: SurveyTheme {
        SurveyTheme(
            background: dynamic(light: rgb(0x09, 0x09, 0x0B, 0.45),
                                dark:  rgb(0x00, 0x00, 0x00, 0.55)),
            surface:    dynamic(light: rgb(0xFF, 0xFF, 0xFF),
                                dark:  rgb(0x1A, 0x1A, 0x1E)),
            text:       dynamic(light: rgb(0x18, 0x18, 0x1B),
                                dark:  rgb(0xFA, 0xFA, 0xFA)),
            secondaryText: dynamic(light: rgb(0x71, 0x71, 0x7A),
                                   dark:  rgb(0xA1, 0xA1, 0xAA)),
            accent:     dynamic(light: rgb(0x63, 0x66, 0xF1),   // indigo-500
                                dark:  rgb(0x81, 0x8C, 0xF8)),  // indigo-400
            accentText: rgb(0xFF, 0xFF, 0xFF),
            border:     dynamic(light: rgb(0xE4, 0xE4, 0xE7),
                                dark:  rgb(0x33, 0x33, 0x38)),
            track:      dynamic(light: rgb(0xF4, 0xF4, 0xF5),
                                dark:  rgb(0x27, 0x27, 0x2A))
        )
    }

    // MARK: Helpers

    /// A `UIFont` that respects Dynamic Type by scaling `size` relative to the
    /// given text style, while keeping the system font + weight we want.
    public static func scaledFont(_ size: CGFloat,
                                  _ weight: UIFont.Weight,
                                  _ style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    /// Builds a `UIColor` that resolves differently in light vs dark mode.
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light }
    }
}
#endif
