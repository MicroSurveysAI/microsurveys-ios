//
//  SurveyComponents.swift
//  MicroSurveysSDK
//
//  Shared building blocks for the question views: the answer protocol + base
//  class, a reusable rounded "chip" button, a lightweight wrapping flow layout
//  (so wide scales like NPS 0–10 wrap gracefully on narrow phones), and the
//  factory that maps a decoded `Question` to its view.
//

#if canImport(UIKit)
import UIKit

// MARK: - Answer protocol

/// Implemented by every question view. The hosting `SurveyViewController` reads
/// `currentAnswer`/`isAnswerValid` and observes `onAnswerChanged` to enable the
/// primary button and collect the result.
public protocol AnswerProviding: AnyObject {
    /// The current answer, or `nil` if the user hasn't answered yet.
    var currentAnswer: SurveyAnswerValue? { get }
    /// Whether the current state satisfies the question's `required` rule.
    var isAnswerValid: Bool { get }
    /// Called whenever the answer changes (selection, typing, etc.).
    var onAnswerChanged: (() -> Void)? { get set }
}

// MARK: - Base question view

/// Common storage + default validity logic for question views. Subclasses build
/// their controls in `setUp()` and override `currentAnswer` (and, if needed,
/// `isAnswerValid`).
open class QuestionBaseView: UIView, AnswerProviding {
    public let question: Question
    public let theme: SurveyTheme
    public var onAnswerChanged: (() -> Void)?

    public init(question: Question, theme: SurveyTheme) {
        self.question = question
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setUp()
    }

    @available(*, unavailable)
    required public init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Override to build the view hierarchy.
    open func setUp() {}

    /// Override to expose the current answer.
    open var currentAnswer: SurveyAnswerValue? { nil }

    /// Default: a required question is valid once it has an answer; an optional
    /// one is always valid. `OpenTextView` overrides this for non-empty checks.
    open var isAnswerValid: Bool {
        question.isRequired ? currentAnswer != nil : true
    }

    /// Subclasses call this after any change to notify the controller.
    public func notifyChanged() { onAnswerChanged?() }
}

// MARK: - Chip button

/// A rounded, tappable control used for scale numbers and as the base look for
/// other selectable controls. Selected state fills with the accent color.
public final class ChipButton: UIButton {
    private let theme: SurveyTheme
    /// Minimum square side so single-digit chips stay tappable & uniform.
    private let minSide: CGFloat

    public init(theme: SurveyTheme, minSide: CGFloat = 44) {
        self.theme = theme
        self.minSide = minSide
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        titleLabel?.font = theme.chipFont
        titleLabel?.adjustsFontForContentSizeCategory = true
        layer.cornerRadius = theme.controlCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        applyState()
    }

    public override var isSelected: Bool {
        didSet { applyState() }
    }

    public override var isHighlighted: Bool {
        didSet {
            // Subtle press feedback.
            alpha = isHighlighted ? 0.85 : 1
        }
    }

    private func applyState() {
        if isSelected {
            backgroundColor = theme.accent
            layer.borderColor = theme.accent.cgColor
            setTitleColor(theme.accentText, for: .normal)
        } else {
            backgroundColor = theme.surface
            layer.borderColor = theme.border.cgColor
            setTitleColor(theme.text, for: .normal)
        }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Re-resolve dynamic CGColors on light/dark switch.
        applyState()
    }

    public override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: max(s.width, minSide), height: max(s.height, minSide))
    }
}

// MARK: - Flow layout view

/// A minimal flow-layout container: lays out its items left-to-right and wraps
/// to new rows when they don't fit the available width. Reports its required
/// height via `intrinsicContentSize` so it plays nicely with Auto Layout /
/// stack views. Used for scale and emoji rows.
public final class FlowLayoutView: UIView {
    public enum Alignment { case leading, center }

    public var itemSpacing: CGFloat = 8
    public var lineSpacing: CGFloat = 8
    public var alignment: Alignment = .center

    private var items: [UIView] = []
    private var computedHeight: CGFloat = 0

    public func setItems(_ views: [UIView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let maxWidth = bounds.width
        guard maxWidth > 0, !items.isEmpty else { return }

        // Group items into rows that fit within maxWidth.
        var rows: [[(view: UIView, size: CGSize)]] = []
        var row: [(view: UIView, size: CGSize)] = []
        var rowWidth: CGFloat = 0
        for v in items {
            let size = v.intrinsicContentSize
            let needed = (row.isEmpty ? 0 : itemSpacing) + size.width
            if !row.isEmpty, rowWidth + needed > maxWidth {
                rows.append(row)
                row = []
                rowWidth = 0
            }
            rowWidth += (row.isEmpty ? 0 : itemSpacing) + size.width
            row.append((v, size))
        }
        if !row.isEmpty { rows.append(row) }

        // Position each row.
        var y: CGFloat = 0
        for r in rows {
            let totalWidth = r.reduce(0) { $0 + $1.size.width }
                + CGFloat(max(0, r.count - 1)) * itemSpacing
            var x: CGFloat = alignment == .center ? max(0, (maxWidth - totalWidth) / 2) : 0
            let rowHeight = r.map { $0.size.height }.max() ?? 0
            for item in r {
                item.view.frame = CGRect(x: x,
                                         y: y + (rowHeight - item.size.height) / 2,
                                         width: item.size.width,
                                         height: item.size.height)
                x += item.size.width + itemSpacing
            }
            y += rowHeight + lineSpacing
        }

        let newHeight = max(0, y - lineSpacing)
        if abs(newHeight - computedHeight) > 0.5 {
            computedHeight = newHeight
            invalidateIntrinsicContentSize()
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: computedHeight)
    }
}

// MARK: - Factory

/// Maps a decoded `Question` to the matching view. Centralizes the switch so
/// the controller stays type-agnostic.
public enum QuestionViewFactory {
    public static func make(for question: Question, theme: SurveyTheme) -> QuestionBaseView {
        switch question.type {
        case .ces:
            return CESScaleView(question: question, theme: theme)
        case .nps:
            return NPSScaleView(question: question, theme: theme)
        case .csatStar:
            return StarRatingView(question: question, theme: theme)
        case .csatEmoji:
            return EmojiScaleView(question: question, theme: theme)
        case .thumbs:
            return ThumbsView(question: question, theme: theme)
        case .singleChoice:
            return SingleChoiceView(question: question, theme: theme)
        case .openText:
            return OpenTextView(question: question, theme: theme)
        }
    }
}
#endif
