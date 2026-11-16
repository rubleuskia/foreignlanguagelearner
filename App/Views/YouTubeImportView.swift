import SwiftUI
import SwiftData
import WebKit

struct YouTubeImportView: View {
    var incoming: YouTubeImport? = nil
    var inboxURL: URL? = nil
    var replacing: LearningItem? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var link = ""
    @State private var browser: YouTubeBrowserSession?
    @State private var payload: YouTubeImport?
    @State private var language = "en"
    @State private var busy = false
    @State private var error: String?
    @State private var replacementRevision: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack {
                if let payload {
                    Form {
                        Section("YouTube") { Text(payload.title); Text("\(payload.cues.count) subtitle segments") }
                        Text(AppLanguage.format("Captured subtitles: %@", SourceLanguage.name(for: payload.language)))
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Choose different subtitles") {
                            if browser == nil { browser = YouTubeBrowserSession(videoID: payload.videoID) }
                            self.payload = nil
                            error = nil
                        }.disabled(busy)
                        Text("To change the language, choose subtitles in the YouTube player and capture again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("The video streams from YouTube. The transcript is saved on this device. Internet is required to watch.")
                        Button(AppLanguage.text(replacing == nil ? "Add to library" : "Replace subtitles")) {
                            saveTask = Task { await save(payload) }
                        }.disabled(busy || !SourceLanguage.isSupported(language))
                            .accessibilityIdentifier("youtube.save")
                    }
                } else if let browser {
                    Text("Play the video and enable subtitles in the desired language, then tap Get subtitles.")
                        .font(.caption).padding(.horizontal)
                    YouTubeImportBrowser(session: browser)
                    Button("Get subtitles") { Task { await capture(browser) } }
                        .disabled(busy).padding().accessibilityIdentifier("youtube.capture")
                } else {
                    Form {
                        Section("YouTube video") {
                            TextField("Paste YouTube link", text: $link).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("youtube.link")
                            Button("Open video") { open() }.accessibilityIdentifier("youtube.open")
                            Button("Open YouTube", systemImage: "magnifyingglass") {
                                error = nil
                                browser = YouTubeBrowserSession()
                            }.accessibilityIdentifier("youtube.browse")
                        }
                        Text("You can also open a video in Safari, enable subtitles, and share it to Language Learner.")
                    }
                }
                if busy { ProgressView() }
                if let error { Text(AppLanguage.text(error)).foregroundStyle(.red).font(.caption).padding() }
            }
            .navigationTitle("Import YouTube")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear {
                if replacementRevision == nil { replacementRevision = replacing?.resourceRevision }
                if let incoming { accept(incoming) }
                else if browser == nil, let id = replacing?.youtubeVideoID {
                    browser = YouTubeBrowserSession(videoID: id)
                }
            }
            .onDisappear {
                saveTask?.cancel()
                browser?.webView.stopLoading()
                browser?.webView.loadHTMLString("", baseURL: nil)
            }
        }
    }

    private func open() {
        guard let id = YouTubeImport.videoID(from: link) else { error = "Enter a valid HTTPS YouTube video link."; return }
        error = nil
        browser = YouTubeBrowserSession(videoID: id)
    }
    private func accept(_ value: YouTubeImport) {
        payload = value
        let code = value.language.split(separator: "-").first.map(String.init) ?? "en"
        language = code
        if !SourceLanguage.isSupported(code) { error = "This subtitle language is not supported. Choose another subtitle language in YouTube." }
    }
    private func capture(_ browser: YouTubeBrowserSession) async {
        busy = true; error = nil
        defer { busy = false }
        do { accept(try await browser.capture()) }
        catch { self.error = error.localizedDescription }
    }
    private func save(_ value: YouTubeImport) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try value.validated()
            _ = try VocabularyTokenizer.language(language)
            if let replacing {
                try YouTubeTranscriptUpdateService.replace(value, language: language, item: replacing,
                                                           expectedRevision: replacementRevision, context: context)
                dismiss()
                return
            }
            let id = value.id
            let existing = try context.fetch(FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == id }))
            if existing.isEmpty {
                let cover = await YouTubeCoverService.fetch(videoID: value.videoID)
                try Task.checkCancellation()
                let root = MediaImportService.directory(for: id)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let item = LearningItem(id: id, title: value.title, mediaKind: "youtube", mediaFilename: "",
                    transcriptFilename: "", duration: value.duration,
                    segments: value.cues.map { .init(start: $0.start, end: $0.end, text: $0.text) }, sourceLanguageCode: language)
                item.youtubeVideoID = value.videoID
                item.youtubeSourceURL = "https://www.youtube.com/watch?v=\(value.videoID)"
                item.readingVocabularyMigrationVersion = 1
                context.insert(item)
                do {
                    if let cover {
                        try cover.write(to: root.appending(path: BookCoverService.filename), options: .atomic)
                        item.coverFilename = BookCoverService.filename
                    }
                    try context.save()
                }
                catch { context.delete(item); try? FileManager.default.removeItem(at: root); throw error }
            }
            if let inboxURL { try FileManager.default.removeItem(at: inboxURL) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class YouTubeBrowserSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    init(videoID: String? = nil) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        if let url = Bundle.main.url(forResource: "YouTubeCapture", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        let url = videoID.map { "https://m.youtube.com/watch?v=\($0)" } ?? "https://m.youtube.com/"
        webView.load(URLRequest(url: URL(string: url)!))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", let host = url.host,
              host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "consent.google.com" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func capture() async throws -> YouTubeImport {
        guard let url = Bundle.main.url(forResource: "YouTubeCapture", withExtension: "js") else { throw YouTubeImport.Failure.invalid }
        let script = try String(contentsOf: url, encoding: .utf8)
        let result = try await webView.callAsyncJavaScript(script + "\nreturn JSON.stringify(await captureYouTube());", in: nil, contentWorld: .page)
        guard let text = result as? String, text.utf8.count <= 10_000_000 else { throw YouTubeImport.Failure.invalid }
        let data = Data(text.utf8)
        if let error = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String {
            throw TranscriptParser.ParseError.invalid(error)
        }
        return try JSONDecoder().decode(YouTubeImport.self, from: data).validated()
    }
}

private struct YouTubeImportBrowser: UIViewRepresentable {
    let session: YouTubeBrowserSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
