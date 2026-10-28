import AppKit
import WebKit

/// A pane showing a web page, without browser chrome. Links that would
/// open a new window load in place.
final class WebPaneView: WKWebView, Pane, WKUIDelegate, WKNavigationDelegate {
    weak var delegate: PaneDelegate?
    let pwd: String?
    var bell = false
    var needsConfirmQuit: Bool { false }

    static let blank = URL(string: "about:blank")!

    private var titleObservation: NSKeyValueObservation?
    private var favicon: NSImage?
    private var faviconURL: URL?

    /// `dark` sets the page's prefers-color-scheme.
    init(url: URL, pwd: String?, dark: Bool) {
        self.pwd = pwd
        let configuration = WKWebViewConfiguration()
        // Without Safari's token sites like Google serve a legacy fixed-width
        // layout. Safari's major version matches macOS's since macOS 26.
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(version).0 Safari/605.1.15"
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        uiDelegate = self
        navigationDelegate = self
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The pane card is rounded; keep the page inside it.
        wantsLayer = true
        layer?.cornerRadius = PaneView.cornerRadius
        layer?.masksToBounds = true
        titleObservation = observe(\.title) { [weak self] view, _ in
            self?.delegate?.paneDidUpdate(view)
        }
        if url.isFileURL {
            // shortcut: pages can read files beside them, not in parent folders.
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var tabTitle: String {
        if let title, !title.isEmpty { return title }
        if let url, url.isFileURL { return url.lastPathComponent }
        return url?.host() ?? "Web"
    }

    var tabIcon: NSImage { favicon ?? Self.globe }

    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: "Web page") ?? NSImage()

    func teardown() {
        titleObservation = nil
        stopLoading()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { delegate?.paneDidFocus(self) }
        return result
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
    }

    /// The page's `<link rel="icon">`, else /favicon.ico.
    private func loadFavicon() {
        let script = """
            (document.querySelector('link[rel~="icon"]') ?? document.querySelector('link[rel="apple-touch-icon"]'))?.href
              ?? new URL('/favicon.ico', location.href).href
            """
        evaluateJavaScript(script) { [weak self] result, _ in
            guard let self, let href = result as? String, let url = URL(string: href), url != faviconURL else { return }
            faviconURL = url
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                let image = data.flatMap(NSImage.init(data:))
                DispatchQueue.main.async { [weak self] in
                    // A later navigation may have asked for another icon.
                    guard let self, faviconURL == url else { return }
                    favicon = image
                    delegate?.paneDidUpdate(self)
                }
            }.resume()
        }
    }

    /// "localhost:3000" -> http://localhost:3000, "example.com" -> https://example.com,
    /// anything else -> Google search.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return URL(string: text) }
        let host = text.prefix { !"/?#".contains($0) }
        let hostName = host.split(separator: ":", maxSplits: 1)[0]
        let local = hostName == "localhost" || hostName.allSatisfy { $0.isNumber || $0 == "." }
        let isURL = !text.contains(" ") && (local || hostName.contains(".") || host.contains(":"))
        if isURL, let url = URL(string: (local ? "http://" : "https://") + text) { return url }
        var search = URLComponents(string: "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }
}
