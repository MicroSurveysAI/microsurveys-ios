//
//  OpenTextView.swift
//  MicroSurveysSDK
//
//  OPEN_TEXT question view: a multi-line text field with placeholder, optional
//  max-length enforcement, and a live character counter. Submits
//  `{ "text": <string> }`.
//

#if canImport(UIKit)
import UIKit

public final class OpenTextView: QuestionBaseView, UITextViewDelegate {

    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let counterLabel = UILabel()

    private var placeholder: String?
    private var maxLength: Int?

    public override func setUp() {
        if case let .openText(ph, max) = question.config {
            placeholder = ph
            maxLength = max
        }

        textView.delegate = self
        textView.font = theme.bodyFont
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = theme.text
        textView.backgroundColor = theme.surface
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.layer.cornerRadius = theme.controlCornerRadius
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = theme.border.cgColor
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.keyboardType = .default
        textView.returnKeyType = .default
        addSubview(textView)

        placeholderLabel.text = placeholder
        placeholderLabel.font = theme.bodyFont
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = theme.secondaryText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isHidden = (placeholder?.isEmpty ?? true)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        counterLabel.font = theme.captionFont
        counterLabel.adjustsFontForContentSizeCategory = true
        counterLabel.textColor = theme.secondaryText
        counterLabel.textAlignment = .right
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        counterLabel.isHidden = (maxLength == nil)
        addSubview(counterLabel)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),

            // Placeholder sits inside the text view's inset.
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -16),

            counterLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 6),
            counterLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            counterLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if maxLength == nil {
            // No counter — let the text view define the bottom.
            textView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }

        updateCounter()
    }

    private var trimmedText: String {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateCounter() {
        guard let maxLength = maxLength else { return }
        counterLabel.text = "\(textView.text.count)/\(maxLength)"
    }

    // MARK: UITextViewDelegate

    public func textView(_ textView: UITextView,
                         shouldChangeTextIn range: NSRange,
                         replacementText text: String) -> Bool {
        guard let maxLength = maxLength else { return true }
        let current = textView.text as NSString
        let updated = current.replacingCharacters(in: range, with: text)
        return updated.count <= maxLength
    }

    public func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateCounter()
        notifyChanged()
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        textView.layer.borderColor = theme.accent.cgColor
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        textView.layer.borderColor = theme.border.cgColor
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if !textView.isFirstResponder {
            textView.layer.borderColor = theme.border.cgColor
        }
    }

    // MARK: Answer

    public override var currentAnswer: SurveyAnswerValue? {
        trimmedText.isEmpty ? nil : .text(trimmedText)
    }

    /// Required open-text questions need non-empty text; optional ones are
    /// always valid (an empty answer is simply omitted by the controller).
    public override var isAnswerValid: Bool {
        question.isRequired ? !trimmedText.isEmpty : true
    }
}
#endif
