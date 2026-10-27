import AppKit
import WebKit

/// A pane showing a web page, without browser chrome. Links that would
/// open a new window load in place.
final class WebPaneView: WKWebView, Pane, WKUIDelegate {
    weak var delegate: PaneDelegate?
    let pwd: String?
    var bell = false
    var needsConfirmQuit: Bool { false }

    private var titleObservation: NSKeyValueObservation?

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
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The pane card is rounded; keep the page inside it.
        wantsLayer = true
        layer?.cornerRadius = PaneView.cornerRadius
        layer?.masksToBounds = true
        titleObservation = observe(\.title) { [weak self] view, _ in
            self?.delegate?.paneDidUpdate(view)
        }
        load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var tabTitle: String {
        if let title, !title.isEmpty { return title }
        return url?.host() ?? "Web"
    }

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

    /// "localhost:3000" -> http://localhost:3000, "example.com" -> https://example.com.
    static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("://") { return URL(string: text) }
        let local = text.hasPrefix("localhost") || text.first?.isNumber == true
        return URL(string: (local ? "http://" : "https://") + text)
    }
}
