import SwiftUI
import SwiftData
import WebKit

struct YouTubeImportView: View {
    var incoming: YouTubeImport? = nil
    var inboxURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var link = ""
    @State private var browser: YouTubeBrowserSession?
    @State private var payload: YouTubeImport?
    @State private var language = "en"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack {
                if let payload {
                    Form {
                        Section("YouTube") { Text(payload.title); Text("\(payload.cues.count) subtitle segments") }
                        Picker("Source language", selection: $language) {
                            ForEach(SourceLanguage.supportedCodes.sorted(), id: \.self) { code in
                                Text(SourceLanguage.name(for: code)).tag(code)
                            }
                        }
                        Text("The video streams from YouTube. The transcript is saved on this device. Internet is required to watch.")
                        Button("Add to library") { save(payload) }.disabled(busy)
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
                        }
                        Text("You can also open a video in Safari, enable subtitles, and share it to Language Learner.")
                    }
                }
                if busy { ProgressView() }
                if let error { Text(AppLanguage.text(error)).foregroundStyle(.red).font(.caption).padding() }
            }
            .navigationTitle("Import YouTube")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if let incoming { accept(incoming) } }
            .onDisappear { browser?.webView.stopLoading(); browser?.webView.loadHTMLString("", baseURL: nil) }
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
        language = SourceLanguage.isSupported(code) ? code : "en"
        if !SourceLanguage.isSupported(code) { error = "Choose a supported source language before saving this transcript." }
    }
    private func capture(_ browser: YouTubeBrowserSession) async {
        busy = true; error = nil
        defer { busy = false }
        do { accept(try await browser.capture()) }
        catch { self.error = error.localizedDescription }
    }
    private func save(_ value: YouTubeImport) {
        do {
            let value = try value.validated()
            _ = try VocabularyTokenizer.language(language)
            let id = value.id
            let existing = try context.fetch(FetchDescriptor<LearningItem>(predicate: #Predicate { $0.id == id }))
            if existing.isEmpty {
                let root = MediaImportService.directory(for: id)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let item = LearningItem(id: id, title: value.title, mediaKind: "youtube", mediaFilename: "",
                    transcriptFilename: "", duration: value.duration,
                    segments: value.cues.map { .init(start: $0.start, end: $0.end, text: $0.text) }, sourceLanguageCode: language)
                item.youtubeVideoID = value.videoID
                item.readingVocabularyMigrationVersion = 1
                context.insert(item)
                do { try context.save() }
                catch { context.delete(item); try? FileManager.default.removeItem(at: root); throw error }
            }
            if let inboxURL { try FileManager.default.removeItem(at: inboxURL) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class YouTubeBrowserSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    init(videoID: String) {
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
        webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(videoID)")!))
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
