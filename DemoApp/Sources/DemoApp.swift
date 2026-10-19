//
//  DemoApp.swift
//  MicroSurveysDemo
//
//  A tiny host app that presents each question type through the SDK's public
//  `MicroSurveysUI.present` entry point, so the survey UI can be checked on any
//  simulator / OS version without wiring up a backend or Amplitude.
//

import UIKit
import MicroSurveysSDK

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: DemoListViewController())
        window.makeKeyAndVisible()
        self.window = window
    }
}

// MARK: - Sample surveys

struct DemoSurvey {
    let title: String
    let subtitle: String
    let questionsJSON: String

    var survey: Survey {
        let json = #"{ "id": "demo", "name": "\#(title)", "questions": [\#(questionsJSON)] }"#
        do {
            return try JSONDecoder().decode(Survey.self, from: Data(json.utf8))
        } catch {
            fatalError("Bad demo survey JSON for \(title): \(error)")
        }
    }

    static let all: [DemoSurvey] = [
        DemoSurvey(title: "CSAT – Emoji", subtitle: "Crashed on open (iOS 27)", questionsJSON: """
            { "id": "q1", "type": "CSAT_EMOJI", "prompt": "How was your overall ride experience?", "required": true,
              "config": { "options": [
                { "value": "1", "emoji": "😡", "label": "Awful" },
                { "value": "2", "emoji": "🙁", "label": "Bad" },
                { "value": "3", "emoji": "😐", "label": "Okay" },
                { "value": "4", "emoji": "🙂", "label": "Good" },
                { "value": "5", "emoji": "😍", "label": "Great" } ] } }
            """),
        DemoSurvey(title: "NPS 0–10", subtitle: "Sheet didn't expand fully", questionsJSON: """
            { "id": "q1", "type": "NPS", "prompt": "How likely are you to recommend us to a friend?", "required": true,
              "config": { "min": 0, "max": 10, "minLabel": "Not likely", "maxLabel": "Very likely" } }
            """),
        DemoSurvey(title: "CSAT – Stars", subtitle: "Selected stars drew a filled box", questionsJSON: """
            { "id": "q1", "type": "CSAT_STAR", "prompt": "How was your overall ride experience?", "required": true,
              "config": { "count": 5 } }
            """),
        DemoSurvey(title: "CES 1–7", subtitle: "Wallet effort survey", questionsJSON: """
            { "id": "q1", "type": "CES", "prompt": "How easy was it to understand your wallet balance?", "required": true,
              "config": { "min": 1, "max": 7, "minLabel": "Very difficult", "maxLabel": "Very easy" } }
            """),
        DemoSurvey(title: "Thumbs", subtitle: "", questionsJSON: """
            { "id": "q1", "type": "THUMBS", "prompt": "Was this helpful?", "required": true, "config": {} }
            """),
        DemoSurvey(title: "Single choice", subtitle: "", questionsJSON: """
            { "id": "q1", "type": "SINGLE_CHOICE", "prompt": "What brought you here today?", "required": true,
              "config": { "options": [
                { "value": "ride", "label": "Book a ride" },
                { "value": "wallet", "label": "Check my wallet" },
                { "value": "support", "label": "Get support" } ] } }
            """),
        DemoSurvey(title: "Open text", subtitle: "", questionsJSON: """
            { "id": "q1", "type": "OPEN_TEXT", "prompt": "Anything else you'd like to tell us?", "required": false,
              "config": { "placeholder": "Type here…", "maxLength": 280 } }
            """),
        DemoSurvey(title: "Multi-question", subtitle: "Emoji → NPS → Stars → Text", questionsJSON: """
            { "id": "q1", "order": 0, "type": "CSAT_EMOJI", "prompt": "How was your ride?", "required": true,
              "config": { "options": [
                { "value": "1", "emoji": "🙁", "label": "Bad" },
                { "value": "2", "emoji": "😐", "label": "Okay" },
                { "value": "3", "emoji": "😍", "label": "Great" } ] } },
            { "id": "q2", "order": 1, "type": "NPS", "prompt": "How likely are you to recommend us?", "required": true,
              "config": { "min": 0, "max": 10 } },
            { "id": "q3", "order": 2, "type": "CSAT_STAR", "prompt": "Rate your driver", "required": true,
              "config": { "count": 5 } },
            { "id": "q4", "order": 3, "type": "OPEN_TEXT", "prompt": "Anything else?", "required": false, "config": {} }
            """)
    ]
}

// MARK: - List

final class DemoListViewController: UITableViewController {

    private enum Style: Int, CaseIterable {
        case defaultTheme, coral
        var title: String { self == .defaultTheme ? "Default" : "Coral (pill)" }
    }

    private let styleControl = UISegmentedControl(items: Style.allCases.map(\.title))
    private let positionControl = UISegmentedControl(items: ["Bottom sheet", "Center dialog"])
    private var lastResult = "—"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "MicroSurveys Demo"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        styleControl.selectedSegmentIndex = 1
        positionControl.selectedSegmentIndex = 0

        let header = UIStackView(arrangedSubviews: [styleControl, positionControl])
        header.axis = .vertical
        header.spacing = 8
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        header.frame.size.height = 96
        tableView.tableHeaderView = header
    }

    private var theme: SurveyTheme {
        var theme = SurveyTheme.default
        if Style(rawValue: styleControl.selectedSegmentIndex) == .coral {
            theme.accent = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
            theme.accentText = UIColor(red: 0.07, green: 0.11, blue: 0.30, alpha: 1)
            theme.text = UIColor(red: 0.07, green: 0.11, blue: 0.30, alpha: 1)
            // Tall pill controls, as the Presenter maps `controlPill: true`. Seven of these in a
            // row end up narrower than they are tall, which used to draw lens-shaped chips.
            theme.controlHeight = 60
            theme.controlCornerRadius = theme.controlHeight / 2
        }
        theme.position = positionControl.selectedSegmentIndex == 0 ? .bottom : .center
        return theme
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? DemoSurvey.all.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Present a survey" : "Last result"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if indexPath.section == 0 {
            let demo = DemoSurvey.all[indexPath.row]
            content.text = demo.title
            content.secondaryText = demo.subtitle.isEmpty ? nil : demo.subtitle
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        } else {
            content.text = lastResult
            content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            content.textProperties.numberOfLines = 0
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        autoPresentFromLaunchArguments()
    }

    /// Scripting hooks for screenshots from the command line (simctl can't tap):
    ///   `-present <row>` opens that survey on launch; `-select <n>` then taps its nth control (1-based).
    ///   `-position center` uses the center dialog.
    private var didAutoPresent = false
    private func autoPresentFromLaunchArguments() {
        let defaults = UserDefaults.standard
        guard !didAutoPresent, defaults.object(forKey: "present") != nil else { return }
        didAutoPresent = true
        if defaults.string(forKey: "position") == "center" { positionControl.selectedSegmentIndex = 1 }
        let row = defaults.integer(forKey: "present")
        guard DemoSurvey.all.indices.contains(row) else { return }
        present(DemoSurvey.all[row])
        if defaults.bool(forKey: "dumpLayout") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let root = self?.presentedViewController?.view else { return }
                print("DUMP view.safeAreaInsets=\(root.safeAreaInsets) frame=\(root.frame)")
                for sv in root.descendants(ofType: UIScrollView.self) {
                    print("DUMP scroll frame=\(sv.frame) adjustedInset=\(sv.adjustedContentInset) behavior=\(sv.contentInsetAdjustmentBehavior.rawValue) contentSize=\(sv.contentSize)")
                }
                for l in root.descendants(ofType: UILabel.self) where (l.text?.count ?? 0) > 12 {
                    print("DUMP label '\(l.text!.prefix(20))' frameInRoot=\(l.convert(l.bounds, to: root))")
                }
                for q in root.descendants(ofType: QuestionBaseView.self) {
                    print("DUMP question frameInRoot=\(q.convert(q.bounds, to: root))")
                }
            }
        }
        let select = defaults.integer(forKey: "select")
        guard select > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let root = self?.presentedViewController?.view else { return }
            let controls = root.descendants(ofType: UIControl.self)
                .filter { $0.superview?.superview is QuestionBaseView || $0.superview is QuestionBaseView }
            if controls.indices.contains(select - 1) { controls[select - 1].sendActions(for: .touchUpInside) }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { return }
        present(DemoSurvey.all[indexPath.row])
    }

    private func present(_ demo: DemoSurvey) {
        MicroSurveysUI.present(survey: demo.survey, on: self, theme: theme) { [weak self] result in
            let answers = result.answers.compactMap { answer -> String? in
                guard let data = try? JSONEncoder().encode(answer) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            self?.lastResult = "completed=\(result.completed) dismissed=\(result.dismissed)\n"
                + answers.joined(separator: "\n")
            self?.tableView.reloadSections([1], with: .none)
        }
    }
}

private extension UIView {
    func descendants<T: UIView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { (($0 as? T).map { [$0] } ?? []) + $0.descendants(ofType: type) }
    }
}
