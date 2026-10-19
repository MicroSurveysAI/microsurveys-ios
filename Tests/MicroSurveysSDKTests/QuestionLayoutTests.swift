#if canImport(UIKit)
import XCTest
import UIKit
@testable import MicroSurveysSDK

/// Layout regressions for the question views, run inside a real window so UIKit's layout engine
/// behaves the way it does in a host app.
final class QuestionLayoutTests: XCTestCase {

    private func host(_ view: UIView, width: CGFloat = 343) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width + 32, height: 800))
        let vc = UIViewController()
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: 100),
            view.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            view.widthAnchor.constraint(equalToConstant: width)
        ])
        window.layoutIfNeeded()
        return window
    }

    private func question(_ type: QuestionType, _ config: QuestionConfig) -> Question {
        Question(id: "q", order: 0, type: type, prompt: "?", isRequired: true, config: config)
    }

    /// CSAT emoji crashed on iOS 27 when the view was laid out.
    func testEmojiViewLaysOut() {
        let options = [
            EmojiOption(value: "1", emoji: "😡", label: "Bad"),
            EmojiOption(value: "2", emoji: "😐", label: "Okay"),
            EmojiOption(value: "3", emoji: "😍", label: "Great")
        ]
        let view = EmojiScaleView(question: question(.csatEmoji, .emoji(options: options)), theme: .default)
        let window = host(view)
        XCTAssertGreaterThan(view.bounds.height, 40)
        _ = window
    }

    /// The sheet detent measures the content with `systemLayoutSizeFitting` before the question
    /// view has ever been laid out, so a wrapping NPS 0–10 row must report its full height up front.
    func testNPSFittingHeightBeforeFirstLayout() {
        let view = NPSScaleView(question: question(.nps, .scale(min: 0, max: 10, minLabel: nil, maxLabel: nil)),
                                theme: .default)
        view.setFlowLayoutWidth(343) // what SurveyViewController does before measuring the detent
        let fitted = view.systemLayoutSizeFitting(CGSize(width: 343, height: 0),
                                                  withHorizontalFittingPriority: .required,
                                                  verticalFittingPriority: .fittingSizeLevel).height
        let window = host(view)
        XCTAssertGreaterThan(view.bounds.height, 44 * 2, "11 chips should wrap onto 2 rows at 343pt")
        XCTAssertEqual(fitted, view.bounds.height, accuracy: 0.5)
        _ = window
    }

    /// Selected stars must not draw a tinted background box behind the glyph. A `.system` button
    /// paints one in the selected state (the plate isn't captured by an off-screen snapshot, so
    /// assert on the button type the fix relies on).
    func testStarButtonsAreCustom() {
        let view = StarRatingView(question: question(.csatStar, .stars(count: 5)), theme: .default)
        let buttons = view.allSubviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.count, 5)
        XCTAssertTrue(buttons.allSatisfy { $0.buttonType == .custom })
    }
}

extension QuestionLayoutTests {
    /// When the card is too short for its content, the content must scroll rather than be crushed.
    /// (Otherwise NPS end labels draw over the chips and the second row of chips is cut off.)
    func testShortCardScrollsInsteadOfCompressingContent() throws {
        let json = #"""
        { "id": "s", "name": "NPS", "questions": [
          { "id": "q", "type": "NPS", "prompt": "How likely are you to recommend us to a friend or a colleague?",
            "required": true, "config": { "min": 0, "max": 10, "minLabel": "Not likely", "maxLabel": "Very likely" } } ] }
        """#
        let survey = try JSONDecoder().decode(Survey.self, from: Data(json.utf8))
        var theme = SurveyTheme.default
        theme.position = .center // custom card: its height is capped by the (short) window
        let vc = SurveyViewController(survey: survey, theme: theme)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        window.layoutIfNeeded()

        let flow = try XCTUnwrap(vc.view.allSubviews.compactMap { $0 as? FlowLayoutView }.first)
        let scroll = try XCTUnwrap(vc.view.allSubviews.compactMap { $0 as? UIScrollView }.first)
        XCTAssertEqual(flow.bounds.height, flow.intrinsicContentSize.height, accuracy: 0.5,
                       "the chip row was compressed below its natural height")
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1,
                             "content should overflow and scroll")
    }
}

private extension UIView {
    var allSubviews: [UIView] { subviews + subviews.flatMap { $0.allSubviews } }
}
#endif
