import AppKit
import Foundation
import WebKit

/// Resolves a short public song query and plays the selected public video in a
/// dedicated Chef window. Playback is reported only after YouTube's iframe
/// API emits state 1.
@MainActor
final class YouTubePlayback: NSObject, WKScriptMessageHandler {
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    enum Result {
        case playing(title: String)
        case failed(String)
    }
    private enum LookupResult {
        case candidate(Candidate)
        case failed(String)
    }

    private struct Candidate {
        let id: String
        let title: String
    }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var completion: CheckedContinuation<Result, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var candidateTitle = ""

    func play(query: String) async -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 160 else { return .failed("Enter a song title under 160 characters.") }
        let lookup = await Self.resolve(query: query)
        guard case .candidate(let candidate) = lookup else {
            if case .failed(let reason) = lookup { return .failed(reason) }
            return .failed("YouTube search did not return a playable result.")
        }
        stop()
        candidateTitle = candidate.title

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "chefPlayer")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 540), configuration: config)
        view.allowsBackForwardNavigationGestures = false
        webView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "YouTube — \(candidate.title)"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        let html = Self.playerHTML(videoID: candidate.id)
        view.loadHTMLString(html, baseURL: URL(string: "https://local.chef.starter/"))
        return await withCheckedContinuation { continuation in
            completion = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(18))
                guard !Task.isCancelled else { return }
                self?.finish(.failed("YouTube did not confirm playback. Check the player window; autoplay or embedding may be unavailable."))
            }
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let webView { webView.configuration.userContentController.removeScriptMessageHandler(forName: "chefPlayer") }
        webView?.stopLoading()
        webView = nil
        window?.close()
        window = nil
        if completion != nil { finish(.failed("Playback was stopped.")) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame else { return }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "state", (body["value"] as? Int) == 1 {
            finish(.playing(title: candidateTitle))
        } else if kind == "error" {
            finish(.failed("YouTube could not play this video (player error \(body["value"] ?? "unknown"))."))
        } else if kind == "blocked" {
            finish(.failed("YouTube blocked autoplay. Use the controls in the player window to start playback."))
        }
    }

    private func finish(_ result: Result) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = completion
        completion = nil
        continuation?.resume(returning: result)
    }

    private static func resolve(query: String) async -> LookupResult {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: query)]
        guard let url = components.url else { return .failed("The YouTube search URL could not be formed.") }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.url?.host == "www.youtube.com" else {
                if let http = response as? HTTPURLResponse { return .failed("YouTube search returned HTTP \(http.statusCode).") }
                return .failed("YouTube search returned an unexpected response.")
            }
            let byteLimit = 8_000_000
            guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(byteLimit) else {
                return .failed("YouTube search page exceeded the 8 MB response limit.")
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < byteLimit else { return .failed("YouTube search page exceeded the 8 MB response limit.") }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8) else { return .failed("YouTube search response was not valid UTF-8.") }
            guard let found = parseCandidates(html).first else {
                return .failed("YouTube returned its search page, but no valid public video result could be parsed.")
            }
            return .candidate(Candidate(id: found.id, title: found.title))
        } catch { return .failed("YouTube search failed: \(error.localizedDescription)") }
    }

    /// Extract only validated videoRenderer objects from the bounded search page.
    /// Kept pure so fixtures can exercise hostile IDs and malformed payloads.
    nonisolated static func parseCandidates(_ html: String) -> [(id: String, title: String)] {
        guard html.utf8.count <= 8_000_000 else { return [] }
        let marker = "\"videoRenderer\":"
        var cursor = html.startIndex
        var found: [(String, String)] = []
        while found.count < 8, let range = html.range(of: marker, range: cursor..<html.endIndex) {
            cursor = range.upperBound
            guard let open = html[cursor...].firstIndex(of: "{") else { continue }
            var index = open
            var depth = 0
            var quoted = false
            var escaped = false
            var end: String.Index?
            while index < html.endIndex {
                let ch = html[index]
                if quoted {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { quoted = false }
                } else if ch == "\"" { quoted = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { end = html.index(after: index); break }
                }
                index = html.index(after: index)
            }
            guard let end, let data = String(html[open..<end]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["videoId"] as? String,
                  id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                  let title = (object["title"] as? [String: Any])?["runs"] as? [[String: Any]],
                  let text = title.first?["text"] as? String else { continue }
            found.append((id, String(text.prefix(180))))
        }
        return found
    }

    private static func playerHTML(videoID: String) -> String {
        // ID is constrained to YouTube's 11-character alphabet before interpolation.
        """
        <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin"><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#player{margin:0;width:100%;height:100%;background:#080b12}</style></head><body><div id="player"></div><script>
        var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';document.head.appendChild(tag);
        function report(kind,value){window.webkit.messageHandlers.chefPlayer.postMessage({kind:kind,value:value});}
        function onYouTubeIframeAPIReady(){new YT.Player('player',{width:'100%',height:'100%',videoId:'\(videoID)',playerVars:{autoplay:1,playsinline:1,enablejsapi:1,origin:'https://local.chef.starter'},events:{onReady:function(e){e.target.playVideo();},onStateChange:function(e){report('state',e.data);},onError:function(e){report('error',e.data);},onAutoplayBlocked:function(){report('blocked',1);}}});}
        </script></body></html>
        """
    }

    nonisolated static func test() {
        let fixture = #"{"videoRenderer":{"videoId":"dQw4w9WgXcQ","title":{"runs":[{"text":"Song"}]}}}"#
        precondition(parseCandidates(fixture).first?.id == "dQw4w9WgXcQ")
        let hostile = #"{"videoRenderer":{"videoId":"../../evil","title":{"runs":[{"text":"bad"}]}}}"#
        precondition(parseCandidates(hostile).isEmpty)
        precondition(parseCandidates(String(repeating: "x", count: 8_000_001)).isEmpty)
    }
}
