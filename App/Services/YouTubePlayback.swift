import SwiftUI
import WebKit
import Observation

@MainActor @Observable final class YouTubePlayback: NSObject, WKScriptMessageHandler {
    var position = 0.0
    var isPlaying = false
    var error: String?
    var webView: WKWebView?

    func pause() { webView?.evaluateJavaScript("player?.pauseVideo()", completionHandler: nil) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        if let code = value["error"] as? Int {
            error = "YouTube cannot play this video here (\(code)). It may be unavailable or embedding may be disabled."
        }
        if let time = value["time"] as? Double, time.isFinite, time >= 0 { position = time }
        if let playing = value["playing"] as? Bool { isPlaying = playing }
    }
}

struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String
    let start: Double
    let playback: YouTubePlayback

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(playback, name: "youtube")
        let view = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        view.isInspectable = true
        #endif
        view.scrollView.isScrollEnabled = false
        playback.webView = view
        // Only validated IDs and numeric positions are interpolated into the player document.
        guard YouTubeImport.videoID(from: "https://www.youtube.com/watch?v=\(videoID)") == videoID else { return view }
        let initial = start.isFinite ? max(0, start) : 0
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:black}</style></head>
        <body><div id="player"></div><script>
        var player;
        function onYouTubeIframeAPIReady(){player=new YT.Player('player',{
          videoId:'\(videoID)',playerVars:{playsinline:1,autoplay:0,start:\(Int(initial)),origin:'https://com.rubleuskia.foreignlanguagelearner'},
          events:{onError:e=>webkit.messageHandlers.youtube.postMessage({error:e.data})}
        });}
        setInterval(()=>{if(player&&player.getCurrentTime)webkit.messageHandlers.youtube.postMessage({
          time:player.getCurrentTime(),playing:player.getPlayerState()===1});},200);
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """, baseURL: URL(string: "https://com.rubleuskia.foreignlanguagelearner"))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ()) {
        view.evaluateJavaScript("player?.pauseVideo()", completionHandler: nil)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "youtube")
        view.stopLoading()
    }
}
