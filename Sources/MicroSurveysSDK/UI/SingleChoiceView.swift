//
//  SingleChoiceView.swift
//  MicroSurveysSDK
//
//  SINGLE_CHOICE question view: a vertical list of selectable rows (radio-style).
//  Selecting a row highlights it and shows a check. Submits
//  `{ "choice": <option value> }`.
//

#if canImport(UIKit)
import UIKit

public final class SingleChoiceView: QuestionBaseView {

    private var options: [ChoiceOption] = []
    private var rows: [ChoiceRow] = []
    private var selectedValue: String?

    public override func setUp() {
        if case let .singleChoice(opts) = question.config { options = opts }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        rows = options.enumerated().map { index, option in
            let row = ChoiceRow(option: option, theme: theme)
            row.tag = index
            let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
            row.addGestureRecognizer(tap)
            row.isAccessibilityElement = true
            row.accessibilityTraits = .button
            row.accessibilityLabel = option.label
            return row
        }
        rows.forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func rowTapped(_ gesture: UITapGestureRecognizer) {
        guard let row = gesture.view as? ChoiceRow else { return }
        selectedValue = options[row.tag].value
        for r in rows { r.setSelected(r.tag == row.tag) }
        notifyChanged()
    }

    public override var currentAnswer: SurveyAnswerValue? {
        guard let value = selectedValue else { return nil }
        return .choice(value)
    }
}

/// One option row: label on the left, a radio indicator on the right.
final class ChoiceRow: UIView {
    private let theme: SurveyTheme
    private let indicator = UIImageView()
    private let label = UILabel()
    private var isSelectedState = false

    init(option: ChoiceOption, theme: SurveyTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        layer.cornerRadius = theme.controlCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1

        label.text = option.label
        label.font = theme.bodyFont
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = theme.text
        label.translatesAutoresizingMaskIntoConstraints = false

        indicator.contentMode = .scaleAspectFit
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(label)
        addSubview(indicator)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            indicator.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            indicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 22),
            indicator.heightAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(greaterThanOrEqualToConstant: theme.controlHeight)
        ])

        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        backgroundColor = selected ? theme.accent.withAlphaComponent(0.10) : theme.surface
        layer.borderColor = (selected ? theme.accent : theme.border).cgColor
        let symbol = selected ? "checkmark.circle.fill" : "circle"
        indicator.image = UIImage(systemName: symbol)
        indicator.tintColor = selected ? theme.accent : theme.border
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Re-resolve dynamic CGColors on light/dark switch.
        setSelected(isSelectedState)
    }
}
#endif
