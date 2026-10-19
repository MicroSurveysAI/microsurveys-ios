//
//  StarRatingView.swift
//  MicroSurveysSDK
//
//  CSAT_STAR question view: a row of `count` tappable stars. Tapping a star
//  selects it and all stars before it. Submits `{ "value": <1...count> }`.
//

#if canImport(UIKit)
import UIKit

public final class StarRatingView: QuestionBaseView {

    private var starButtons: [UIButton] = []
    private var rating: Int = 0    // 0 = none selected
    private var count: Int = 5

    public override func setUp() {
        if case let .stars(c) = question.config { count = max(1, c) }

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fillEqually
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let config = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        starButtons = (1...count).map { index in
            // `.custom`, not `.system`: a system button in the selected state paints a tinted
            // background plate behind its image on newer iOS, which drew solid boxes behind the
            // filled stars. A custom button just swaps the image.
            let b = UIButton(type: .custom)
            b.tag = index
            let filled = UIImage(systemName: "star.fill", withConfiguration: config)
            b.setImage(UIImage(systemName: "star", withConfiguration: config), for: .normal)
            b.setImage(filled, for: .selected)
            b.setImage(filled, for: [.selected, .highlighted])
            b.tintColor = theme.accent
            b.accessibilityLabel = "\(index) star\(index == 1 ? "" : "s")"
            b.addTarget(self, action: #selector(starTapped(_:)), for: .touchUpInside)
            return b
        }
        starButtons.forEach { row.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @objc private func starTapped(_ sender: UIButton) {
        rating = sender.tag
        for b in starButtons { b.isSelected = (b.tag <= rating) }
        notifyChanged()
    }

    public override var currentAnswer: SurveyAnswerValue? {
        rating > 0 ? .number(rating) : nil
    }
}
#endif
