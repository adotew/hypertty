import AppKit
import WebKit

/// A pane showing a web page, without browser chrome. Links that would
/// open a new window load in place.
final class WebPaneView: WKWebView, Pane, WKUIDelegate, WKNavigationDelegate {
    weak var delegate: PaneDelegate?
    let pwd: String?
    var bell = false
    var needsConfirmQuit: Bool { covered?.needsConfirmQuit ?? false }
    /// Opened in this pane's place (`cave open -i`); closing the page brings it back.
    var covered: (any Pane)?

    static let blank = URL(string: "about:blank")!

    private var titleObservation: NSKeyValueObservation?
    private var favicon: NSImage?
    private var faviconURL: URL?

    /// The theme sets the page's prefers-color-scheme and colors Markdown.
    init(url: URL, pwd: String?, theme: Theme) {
        self.pwd = pwd
        let configuration = WKWebViewConfiguration()
        if let script = Self.markdownScript(theme: theme) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        // Hide scrollbars like the terminal; pages still scroll.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            const style = document.createElement('style')
            style.textContent = '* { scrollbar-width: none } ::-webkit-scrollbar { display: none }'
            document.documentElement.append(style)
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        // Without Safari's token sites like Google serve a legacy fixed-width
        // layout. Safari's major version matches macOS's since macOS 26.
        let version = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        configuration.applicationNameForUserAgent = "Version/\(version).0 Safari/605.1.15"
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        uiDelegate = self
        navigationDelegate = self
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
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
        covered?.teardown()
        titleObservation = nil
        stopLoading()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { delegate?.paneDidFocus(self) }
        return result
    }

    /// Markdown is rendered by our script; the HTML it may contain must not run its own.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if let url = navigationAction.request.url, Self.isMarkdown(url) {
            preferences.allowsContentJavaScript = false
        }
        decisionHandler(.allow, preferences)
    }

    static func isMarkdown(_ url: URL) -> Bool {
        url.isFileURL && ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Defines `renderMarkdown(text)`, which replaces the page with `text` rendered
    /// by marked, in the terminal's colors.
    private static func markdownScript(theme: Theme) -> String? {
        guard let marked = Bundle.main.url(forResource: "marked.umd", withExtension: "js"),
              let source = try? String(contentsOf: marked, encoding: .utf8) else { return nil }
        func css(_ color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "inherit" }
            return "rgb(\(Int(rgb.redComponent * 255)) \(Int(rgb.greenComponent * 255)) \(Int(rgb.blueComponent * 255)) / \(rgb.alphaComponent))"
        }
        let style = """
            html { background: \(css(theme.background)); color: \(css(theme.foreground)); }
            body { font: 15px/1.6 -apple-system, sans-serif; max-width: 800px; margin: 0 auto; padding: 24px 32px; }
            a { color: \(css(theme.accent)); }
            h1, h2 { border-bottom: 1px solid \(css(theme.selection)); padding-bottom: .3em; }
            code, pre { font-family: ui-monospace, monospace; font-size: 13px; background: \(css(theme.selection)); border-radius: 6px; }
            code { padding: .15em .35em; }
            pre { padding: 12px 16px; overflow-x: auto; }
            pre code { padding: 0; background: none; }
            blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid \(css(theme.selection)); color: \(css(theme.secondaryText)); }
            table { border-collapse: collapse; }
            th, td { border: 1px solid \(css(theme.selection)); padding: 6px 12px; }
            img { max-width: 100%; }
            """
        return source + """

            function renderMarkdown(text) {
              const style = document.createElement('style')
              style.textContent = \(String(reflecting: style))
              document.head.append(style)
              document.body.innerHTML = marked.parse(text)
              const h1 = document.querySelector('h1')
              if (h1) document.title = h1.textContent
            }
            """
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFavicon()
        // Read here: WebKit decodes the file as Latin-1.
        if let url, Self.isMarkdown(url), let text = try? String(contentsOf: url, encoding: .utf8) {
            callAsyncJavaScript("renderMarkdown(text)", arguments: ["text": text], in: nil, in: .defaultClient)
        }
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
