//
//  SurveyViewController.swift
//  MicroSurveysSDK
//
//  The bottom-sheet card that hosts a survey: a header (progress + close), the
//  current question view, and a primary Next/Submit button. Handles multi-step
//  navigation, required-answer validation, theming, and reporting the result.
//
//  Presentation:
//   • iOS 15+ uses `UISheetPresentationController` (system bottom sheet, grabber,
//     dimming, interactive dismiss).
//   • iOS 14 falls back to a custom bottom card pinned over a dimmed backdrop.
//

#if canImport(UIKit)
import UIKit

public final class SurveyViewController: UIViewController, UIAdaptivePresentationControllerDelegate {

    // MARK: Inputs

    private let survey: Survey
    private let questions: [Question]
    private let theme: SurveyTheme
    private let completion: ((SurveyResult) -> Void)?

    // MARK: State

    private var index = 0
    private var answers: [String: SurveyAnswerValue] = [:]
    private var reported = false
    private var currentQuestionView: QuestionBaseView?

    /// Whether we present inside a system sheet (iOS 15+) vs the custom card.
    private var usesSystemSheet: Bool {
        guard theme.position == .bottom else { return false } // center → custom centered card
        if #available(iOS 15.0, *) { return true }
        return false
    }

    /// Whether the respondent may close/dismiss without answering (survey-level; default true).
    private var canDismiss: Bool { survey.dismissible ?? true }

    // MARK: Views

    private let dimView = UIView()
    private let card = UIView()
    private let progressLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let promptLabel = UILabel()
    private let scrollView = UIScrollView()
    private let questionContainer = UIView()
    private let primaryButton = UIButton(type: .system)

    private var cardBottomConstraint: NSLayoutConstraint?

    // Captured for the self-sizing sheet detent (iOS 16+): the scrolling content + its metrics.
    private let contentStack = UIStackView()
    private var pad: CGFloat = 0
    private var topInset: CGFloat = 0
    private var hasProgress = false

    // MARK: Init

    public init(survey: Survey,
                theme: SurveyTheme = .default,
                completion: ((SurveyResult) -> Void)? = nil) {
        self.survey = survey
        self.questions = survey.orderedQuestions
        self.theme = theme
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        configurePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configurePresentation() {
        if usesSystemSheet {
            modalPresentationStyle = .pageSheet
            if #available(iOS 16.0, *), let sheet = sheetPresentationController {
                // Self-sizing: one custom detent that fits the content height (no medium/large, so
                // no empty space — the sheet is exactly as tall as the survey needs).
                let fit = UISheetPresentationController.Detent.custom(identifier: .init("msContent")) { [weak self] context in
                    guard let self else { return context.maximumDetentValue }
                    return min(self.measuredContentHeight(), context.maximumDetentValue)
                }
                sheet.detents = [fit]
                sheet.prefersGrabberVisible = true
                if !theme.useNativeSheetCorners { sheet.preferredCornerRadius = theme.cornerRadius }
            } else if #available(iOS 15.0, *), let sheet = sheetPresentationController {
                // iOS 15 has no custom detents — fall back to the system medium/large.
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                if !theme.useNativeSheetCorners { sheet.preferredCornerRadius = theme.cornerRadius }
            }
        } else {
            modalPresentationStyle = .overFullScreen
            modalTransitionStyle = .crossDissolve
        }
        presentationController?.delegate = self
        // Required (non-dismissible) surveys can't be swiped/pulled away.
        isModalInPresentation = !canDismiss
    }

    /// The natural height the sheet should take to fit the survey content (chrome + scrollable
    /// content + button + safe-area insets). Used by the self-sizing custom detent on iOS 16+.
    @available(iOS 16.0, *)
    private func measuredContentHeight() -> CGFloat {
        let width = view.bounds.width > 0 ? view.bounds.width : UIScreen.main.bounds.width
        let contentWidth = max(1, width - pad * 2)
        let contentHeight = contentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel).height
        let top = (hasProgress ? (pad + 30 + theme.spacing) : topInset) + view.safeAreaInsets.top
        let bottom = theme.spacing + theme.controlHeight + pad + view.safeAreaInsets.bottom
        return top + contentHeight + bottom
    }

    // MARK: Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        // Ensure the swipe-to-dismiss callback reaches us (the presentation
        // controller may not have existed yet at init time).
        presentationController?.delegate = self
        buildHierarchy()
        observeKeyboard()
        guard !questions.isEmpty else {
            // Nothing to show — report an immediately-completed empty result.
            report(completed: true, dismissed: false)
            return
        }
        showQuestion(at: 0, animated: false)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !usesSystemSheet { animateCardIn() }
        currentQuestionView?.activate()
    }

    // MARK: Hierarchy

    private func buildHierarchy() {
        if usesSystemSheet {
            view.backgroundColor = theme.surface
        } else {
            view.backgroundColor = .clear
            // Dim backdrop with tap-to-dismiss.
            // Scrim at a fixed ~40% (like a system sheet's dim), regardless of the configured
            // overlay color's own alpha — the dashboard sends an opaque hex.
            dimView.backgroundColor = theme.background.withAlphaComponent(0.4)
            dimView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(dimView)
            NSLayoutConstraint.activate([
                dimView.topAnchor.constraint(equalTo: view.topAnchor),
                dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            if canDismiss {
                dimView.addGestureRecognizer(
                    UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
            }
        }

        // Card container.
        card.backgroundColor = theme.surface
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        if usesSystemSheet {
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
        } else {
            card.layer.cornerRadius = theme.cornerRadius
            card.layer.cornerCurve = .continuous
            card.layer.shadowColor = theme.shadowColor.cgColor
            card.layer.shadowOpacity = theme.shadowOpacity
            card.layer.shadowRadius = theme.shadowRadius
            card.layer.shadowOffset = theme.shadowOffset

            if theme.position == .center {
                // Centered modal card: all corners rounded, inset from edges, vertically centered.
                card.layer.maskedCorners = [
                    .layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
                ]
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                    card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                    card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
                    card.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                ])
            } else {
                // Bottom card (iOS 14 fallback): rounded top corners, pinned to the bottom.
                card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                let bottom = card.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                cardBottomConstraint = bottom
                NSLayoutConstraint.activate([
                    card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    card.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
                    bottom,
                ])
            }
        }

        buildCardContents()
    }

    private func buildCardContents() {
        pad = theme.spacing + 4
        // Extra breathing room at the very top so the title/close button clear the sheet grabber.
        topInset = pad + 12

        // Header: progress label + close button.
        progressLabel.font = theme.captionFont
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.textColor = theme.secondaryText
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        // Classic iOS close button. `UIButton(type: .close)` only draws its circular chrome inside
        // system bars/toolbars — in a plain view (and on iOS 26's Liquid Glass) it renders as a bare
        // X. So we use the system close SYMBOL directly ("xmark.circle.fill" = the gray circle + X),
        // which reads as the native close on every version. No custom background drawing.
        closeButton.setImage(
            UIImage(systemName: "xmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)),
            for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "Close survey"
        closeButton.isHidden = !canDismiss
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .vertical)

        // Prompt (per-question question text).
        promptLabel.font = theme.promptFont
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.textColor = theme.text
        promptLabel.numberOfLines = 0
        promptLabel.textAlignment = theme.alignment
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        questionContainer.translatesAutoresizingMaskIntoConstraints = false

        // Wrap the prompt so we can inset only ITS right edge to clear the close button on
        // single-question surveys. The answer controls below stay full width.
        let promptContainer = UIView()
        promptContainer.translatesAutoresizingMaskIntoConstraints = false
        promptContainer.addSubview(promptLabel)
        let promptRightInset: CGFloat = (questions.count > 1) ? 0 : 34
        NSLayoutConstraint.activate([
            promptLabel.topAnchor.constraint(equalTo: promptContainer.topAnchor),
            promptLabel.bottomAnchor.constraint(equalTo: promptContainer.bottomAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: promptContainer.leadingAnchor),
            promptLabel.trailingAnchor.constraint(equalTo: promptContainer.trailingAnchor, constant: -promptRightInset),
        ])

        // Scrollable middle (prompt + question) so tall surveys / large text fit.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        contentStack.addArrangedSubview(promptContainer)
        contentStack.addArrangedSubview(questionContainer)
        contentStack.axis = .vertical
        contentStack.spacing = theme.spacing + 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        // Primary button.
        primaryButton.titleLabel?.font = theme.buttonFont
        primaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryButton.setTitleColor(theme.accentText, for: .normal)
        primaryButton.backgroundColor = theme.accent
        primaryButton.layer.cornerRadius = theme.controlCornerRadius
        primaryButton.layer.cornerCurve = .continuous
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)

        card.addSubview(progressLabel)
        card.addSubview(closeButton)
        card.addSubview(scrollView)
        card.addSubview(primaryButton)
        // Single-question layout lets content start at the top, overlapping the close-button corner —
        // keep the button above the scroll view so it stays tappable (and fully visible).
        card.bringSubviewToFront(closeButton)

        // The "1 of N" progress only exists for multi-question surveys. For a single question there
        // is no header text, so start the content at the very top (no empty band above the prompt);
        // the close-button corner is cleared by the prompt's own right inset (above), while the
        // answer controls stay full width.
        hasProgress = questions.count > 1
        let scrollTop = hasProgress
            ? scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: theme.spacing)
            : scrollView.topAnchor.constraint(equalTo: card.topAnchor, constant: topInset)
        let contentTrailing = contentStack.trailingAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -pad)

        NSLayoutConstraint.activate([
            // Header.
            closeButton.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            closeButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
            progressLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            progressLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),

            // Scrollable content (top anchor computed above).
            scrollTop,
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor,
                                                  constant: pad),
            contentTrailing,

            // Primary button pinned at the bottom.
            primaryButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: theme.spacing),
            primaryButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            primaryButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            primaryButton.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
            primaryButton.heightAnchor.constraint(equalToConstant: theme.controlHeight)
        ])

        if !usesSystemSheet {
            // The custom card has no fixed height, and a scroll view has no
            // intrinsic height — so make the card hug its content by asking the
            // scroll view to match its content height. This is breakable: when
            // the content is taller than the available space (capped by the
            // card's top inequality), it yields and the content scrolls instead.
            let hug = scrollView.contentLayoutGuide.heightAnchor
                .constraint(equalTo: scrollView.heightAnchor)
            hug.priority = UILayoutPriority(999)
            hug.isActive = true
        }
    }

    /// Sets the prompt text, applying line-height + letter-spacing via attributes when they differ
    /// from the defaults (otherwise plain text, so Dynamic Type and wrapping behave normally).
    private func setPromptText(_ text: String) {
        if theme.promptLineHeightMultiple == 1 && theme.promptLetterSpacing == 0 {
            promptLabel.attributedText = nil
            promptLabel.text = text
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.promptLineHeightMultiple
        paragraph.alignment = theme.alignment
        promptLabel.attributedText = NSAttributedString(string: text, attributes: [
            .font: theme.promptFont,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraph,
            .kern: theme.promptLetterSpacing,
        ])
    }

    // MARK: Navigation

    private func showQuestion(at newIndex: Int, animated: Bool) {
        index = newIndex
        let question = questions[index]

        // Build the question view.
        let questionView = QuestionViewFactory.make(for: question, theme: theme)
        questionView.onAnswerChanged = { [weak self] in self?.updatePrimaryState() }

        // Swap into the container (with an optional crossfade).
        let outgoing = currentQuestionView
        currentQuestionView = questionView
        questionContainer.addSubview(questionView)
        NSLayoutConstraint.activate([
            questionView.topAnchor.constraint(equalTo: questionContainer.topAnchor),
            questionView.leadingAnchor.constraint(equalTo: questionContainer.leadingAnchor),
            questionView.trailingAnchor.constraint(equalTo: questionContainer.trailingAnchor),
            questionView.bottomAnchor.constraint(equalTo: questionContainer.bottomAnchor)
        ])

        // Update chrome.
        setPromptText(question.prompt)
        progressLabel.text = questions.count > 1 ? "\(index + 1) of \(questions.count)" : nil
        let isLast = index == questions.count - 1
        primaryButton.setTitle(isLast ? "Submit" : "Next", for: .normal)
        updatePrimaryState()

        if animated {
            questionView.alpha = 0
            UIView.animate(withDuration: 0.22, animations: {
                questionView.alpha = 1
                outgoing?.alpha = 0
            }, completion: { [weak self] _ in
                outgoing?.removeFromSuperview()
                self?.currentQuestionView?.activate()
            })
        } else {
            outgoing?.removeFromSuperview()
        }

        // Re-fit the self-sizing sheet to this question's content (multi-step surveys).
        if #available(iOS 16.0, *), usesSystemSheet {
            sheetPresentationController?.animateChanges {
                sheetPresentationController?.invalidateDetents()
            }
        }
    }

    private func updatePrimaryState() {
        let valid = currentQuestionView?.isAnswerValid ?? false
        primaryButton.isEnabled = valid
        primaryButton.alpha = valid ? 1 : 0.45
    }

    @objc private func primaryTapped() {
        guard let questionView = currentQuestionView else { return }
        guard questionView.isAnswerValid else { return }

        // Record this question's answer (if any).
        let question = questions[index]
        if let value = questionView.currentAnswer {
            answers[question.id] = value
        }

        if index < questions.count - 1 {
            view.endEditing(true)
            showQuestion(at: index + 1, animated: true)
        } else {
            report(completed: true, dismissed: false)
            dismissSelf()
        }
    }

    @objc private func closeTapped() {
        report(completed: false, dismissed: true)
        dismissSelf()
    }

    // MARK: Result

    private func report(completed: Bool, dismissed: Bool) {
        guard !reported else { return }
        reported = true
        let ordered = questions.compactMap { q -> SurveyAnswer? in
            guard let value = answers[q.id] else { return nil }
            return SurveyAnswer(questionId: q.id, value: value)
        }
        completion?(SurveyResult(surveyId: survey.id,
                                 answers: ordered,
                                 completed: completed,
                                 dismissed: dismissed))
    }

    private func dismissSelf() {
        view.endEditing(true)
        if !usesSystemSheet {
            animateCardOut { [weak self] in self?.dismiss(animated: false) }
        } else {
            dismiss(animated: true)
        }
    }

    // MARK: UIAdaptivePresentationControllerDelegate (interactive/swipe dismiss)

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // User swiped the sheet away without finishing.
        report(completed: false, dismissed: true)
    }

    // MARK: Custom card animation (iOS 14 fallback)

    private func animateCardIn() {
        view.layoutIfNeeded()
        dimView.alpha = 0
        if theme.position == .center {
            card.alpha = 0
            card.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
            UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
                self.card.alpha = 1
                self.card.transform = .identity
                self.dimView.alpha = 1
            }
        } else {
            card.transform = CGAffineTransform(translationX: 0, y: card.bounds.height)
            UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseOut]) {
                self.card.transform = .identity
                self.dimView.alpha = 1
            }
        }
    }

    private func animateCardOut(_ completion: @escaping () -> Void) {
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseIn], animations: {
            if self.theme.position == .center {
                self.card.alpha = 0
                self.card.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            } else {
                self.card.transform = CGAffineTransform(translationX: 0, y: self.card.bounds.height)
            }
            self.dimView.alpha = 0
        }, completion: { _ in completion() })
    }

    // MARK: Keyboard avoidance

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        // Lift content above the keyboard via the safe-area inset (works in both
        // the system sheet and the custom card).
        additionalSafeAreaInsets.bottom = overlap > 0
            ? max(0, overlap - view.safeAreaInsets.bottom + additionalSafeAreaInsets.bottom)
            : 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        additionalSafeAreaInsets.bottom = 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#endif
