//
//  EmojiScaleView.swift
//  MicroSurveysSDK
//
//  CSAT_EMOJI question view: a wrapping row of emoji options, each an emoji
//  glyph above an optional caption. Selecting one highlights it with the accent
//  color. Submits `{ "value": <option value> }`.
//

#if canImport(UIKit)
import UIKit

public final class EmojiScaleView: QuestionBaseView {

    private var options: [EmojiOption] = []
    private var cells: [EmojiCell] = []
    private var selectedValue: String?

    private let flow = FlowLayoutView()

    public override func setUp() {
        if case let .emoji(opts) = question.config { options = opts }

        cells = options.enumerated().map { index, option in
            let cell = EmojiCell(option: option, theme: theme)
            cell.tag = index
            let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped(_:)))
            cell.addGestureRecognizer(tap)
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = option.label ?? option.value
            return cell
        }

        flow.alignment = .center
        flow.itemSpacing = 10
        flow.lineSpacing = 12
        flow.setItems(cells)
        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)

        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: topAnchor),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor),
            flow.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func cellTapped(_ gesture: UITapGestureRecognizer) {
        guard let cell = gesture.view as? EmojiCell else { return }
        let option = options[cell.tag]
        selectedValue = option.value
        for c in cells { c.setSelected(c.tag == cell.tag) }
        notifyChanged()
    }

    public override var currentAnswer: SurveyAnswerValue? {
        guard let value = selectedValue else { return nil }
        return .emoji(value)
    }
}

/// A single emoji option: large glyph + optional caption, in a rounded card.
final class EmojiCell: UIView {
    private let theme: SurveyTheme
    private var isSelectedState = false

    init(option: EmojiOption, theme: SurveyTheme) {
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        layer.cornerRadius = theme.controlCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1

        let emojiLabel = UILabel()
        emojiLabel.text = option.emoji
        emojiLabel.font = .systemFont(ofSize: 32)
        emojiLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [emojiLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        if let caption = option.label, !caption.isEmpty {
            let captionLabel = UILabel()
            captionLabel.text = caption
            captionLabel.font = theme.captionFont
            captionLabel.adjustsFontForContentSizeCategory = true
            captionLabel.textColor = theme.secondaryText
            captionLabel.textAlignment = .center
            stack.addArrangedSubview(captionLabel)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])

        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelected(_ selected: Bool) {
        isSelectedState = selected
        backgroundColor = selected ? theme.accent.withAlphaComponent(0.12) : theme.surface
        layer.borderColor = (selected ? theme.accent : theme.border).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Re-resolve dynamic CGColors on light/dark switch.
        setSelected(isSelectedState)
    }

    override var intrinsicContentSize: CGSize {
        // Let the flow layout measure us via the system fitting size.
        systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}
#endif
