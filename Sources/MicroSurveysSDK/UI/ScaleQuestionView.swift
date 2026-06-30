//
//  ScaleQuestionView.swift
//  MicroSurveysSDK
//
//  Numbered-scale question view shared by CES (1–7) and NPS (0–10). Renders a
//  row of tappable numbered chips that wrap on narrow screens, with optional
//  min/max labels underneath. The selected chip fills with the accent color.
//
//  `CESScaleView` is the PRIMARY launch experience (the wallet effort survey),
//  so this view is the most carefully tuned of the set.
//

#if canImport(UIKit)
import UIKit

/// Generic numbered-scale renderer. Use the `CESScaleView` / `NPSScaleView`
/// subclasses (selected by the factory) so call sites read clearly.
open class ScaleQuestionView: QuestionBaseView {

    private var chips: [ChipButton] = []
    /// The selected scale number, or `nil` if nothing is selected yet.
    private var selectedValue: Int?

    private let flow = FlowLayoutView()
    private let labelsRow = UIStackView()

    public override func setUp() {
        guard case let .scale(rawMin, rawMax, minLabel, maxLabel) = question.config else { return }

        // Defend against a malformed (reversed/equal) range from the backend.
        let lo = Swift.min(rawMin, rawMax)
        let hi = Swift.max(rawMin, rawMax)

        // Chips: one per value in [lo, hi].
        chips = (lo...hi).map { value in
            let chip = ChipButton(theme: theme)
            chip.setTitle("\(value)", for: .normal)
            chip.tag = value
            chip.accessibilityLabel = "\(value)"
            chip.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
            return chip
        }
        flow.alignment = .center
        flow.itemSpacing = 8
        flow.lineSpacing = 8
        flow.setItems(chips)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)

        // End labels (e.g. "Very difficult" … "Very easy").
        labelsRow.axis = .horizontal
        labelsRow.alignment = .top
        labelsRow.distribution = .fill
        labelsRow.translatesAutoresizingMaskIntoConstraints = false

        let hasLabels = (minLabel?.isEmpty == false) || (maxLabel?.isEmpty == false)
        if hasLabels {
            let minView = makeEndLabel(minLabel, alignment: .left)
            let maxView = makeEndLabel(maxLabel, alignment: .right)
            labelsRow.addArrangedSubview(minView)
            labelsRow.addArrangedSubview(maxView)
            minView.widthAnchor.constraint(equalTo: maxView.widthAnchor).isActive = true
            addSubview(labelsRow)
        }

        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        if hasLabels {
            NSLayoutConstraint.activate([
                labelsRow.topAnchor.constraint(equalTo: flow.bottomAnchor, constant: 10),
                labelsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                labelsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                labelsRow.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            flow.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    private func makeEndLabel(_ text: String?, alignment: NSTextAlignment) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 2
        label.font = theme.captionFont
        label.adjustsFontForContentSizeCategory = true
        label.textColor = theme.secondaryText
        label.textAlignment = alignment
        return label
    }

    @objc private func chipTapped(_ sender: ChipButton) {
        selectedValue = sender.tag
        for chip in chips { chip.isSelected = (chip.tag == sender.tag) }
        notifyChanged()
    }

    open override var currentAnswer: SurveyAnswerValue? {
        guard let value = selectedValue else { return nil }
        return .number(value)
    }
}

/// CES (Customer Effort Score), default 1–7. The launch wallet survey.
public final class CESScaleView: ScaleQuestionView {}

/// NPS (Net Promoter Score), default 0–10.
public final class NPSScaleView: ScaleQuestionView {}
#endif
