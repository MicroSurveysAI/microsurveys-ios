//
//  ThumbsView.swift
//  MicroSurveysSDK
//
//  THUMBS question view: a thumbs-up / thumbs-down pair. Selecting one fills it
//  with the accent color. Submits `{ "value": "up" | "down" }`.
//

#if canImport(UIKit)
import UIKit

public final class ThumbsView: QuestionBaseView {

    private enum Side { case up, down }
    private var selected: Side?

    private lazy var upButton = makeButton(symbol: "hand.thumbsup", label: "Thumbs up")
    private lazy var downButton = makeButton(symbol: "hand.thumbsdown", label: "Thumbs down")

    public override func setUp() {
        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [upButton, downButton])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fillEqually
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            upButton.heightAnchor.constraint(equalToConstant: 72),
            upButton.widthAnchor.constraint(equalToConstant: 96),
            downButton.heightAnchor.constraint(equalToConstant: 72),
            downButton.widthAnchor.constraint(equalToConstant: 96)
        ])
        refresh()
    }

    private func makeButton(symbol: String, label: String) -> UIButton {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        b.accessibilityLabel = label
        b.layer.cornerRadius = theme.controlCornerRadius
        b.layer.cornerCurve = .continuous
        b.layer.borderWidth = 1
        return b
    }

    @objc private func upTapped() { selected = .up; refresh(); notifyChanged() }
    @objc private func downTapped() { selected = .down; refresh(); notifyChanged() }

    private func refresh() {
        style(upButton, on: selected == .up)
        style(downButton, on: selected == .down)
    }

    private func style(_ button: UIButton, on: Bool) {
        button.backgroundColor = on ? theme.accent : theme.surface
        button.tintColor = on ? theme.accentText : theme.text
        button.layer.borderColor = (on ? theme.accent : theme.border).cgColor
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refresh()
    }

    public override var currentAnswer: SurveyAnswerValue? {
        switch selected {
        case .up:   return .thumb(.up)
        case .down: return .thumb(.down)
        case .none: return nil
        }
    }
}
#endif
