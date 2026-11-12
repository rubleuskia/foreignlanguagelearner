import UIKit
import UniformTypeIdentifiers

@MainActor final class ShareViewController: UIViewController {
    private let status = UILabel()
    private let action = UIButton(type: .system)
    private var payload: YouTubeImport?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.textAlignment = .center
        status.text = "Loading YouTube subtitles…"
        action.setTitle("Cancel", for: .normal)
        action.addTarget(self, action: #selector(finish), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, action])
        stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        Task { await load() }
    }

    private func load() async {
        do {
            let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            guard let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) else {
                status.text = "Open the YouTube video in Safari, enable subtitles, then use Safari’s Share button. You can also paste the video link in Language Learner."
                return
            }
            let item = try await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier)
            guard let dictionary = item as? [String: Any],
                  let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any],
                  let capture = results["capture"] as? String, capture.utf8.count <= 10_000_000 else { throw YouTubeImport.Failure.unavailable }
            let data = Data(capture.utf8)
            if let error = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
                status.text = error; return
            }
            let value = try JSONDecoder().decode(YouTubeImport.self, from: data).validated()
            guard YouTubeInbox.directory != nil else {
                status.text = "Safari import requires the signed app with shared storage. In this build, paste the video link in Language Learner."
                return
            }
            payload = value
            status.text = "\(value.title)\n\n\(value.language.uppercased()) · \(value.cues.count) subtitle segments\n\nSave this video to Language Learner?"
            action.setTitle("Save to Language Learner", for: .normal)
        } catch { status.text = error.localizedDescription }
    }

    @objc private func finish() {
        guard let payload else { extensionContext?.completeRequest(returningItems: nil); return }
        do {
            try YouTubeInbox.save(payload)
            self.payload = nil
            status.text = "Saved. Open Language Learner to review and add the video to your library."
            action.setTitle("Done", for: .normal)
        } catch { status.text = error.localizedDescription }
    }
}
