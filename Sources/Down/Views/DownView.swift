//
//  DownView.swift
//  Down
//
//  Created by Rob Phillips on 6/1/16.
//  Copyright © 2016-2019 Down. All rights reserved.
//

#if !os(Linux)

#if os(tvOS) || os(watchOS)

// Sorry, not available for tvOS nor watchOS

#else

import WebKit
import SafariServices

// MARK: - Public API

public typealias DownViewClosure = () -> Void

open class DownView: WKWebView {

    // MARK: - Life cycle

    /// Initializes a web view with the results of rendering a CommonMark Markdown string.
    ///
    /// - Parameters:
    ///     - frame: The frame size of the web view
    ///     - markdownString: A string containing CommonMark Markdown
    ///     - openLinksInBrowser: Whether or not to open links using an external browser
    ///     - templateBundle: Optional custom template bundle. Leaving this as `nil` will use the bundle included
    ///       with Down.
    ///     - configuration: Optional custom web view configuration.
    ///     - options: `DownOptions` to modify parsing or rendering, defaulting to `.default`
    ///     - didLoadSuccessfully: Optional callback for when the web content has loaded successfully
    ///     - writableBundle: Whether or not the bundle folder is writable.
    ///
    /// - Throws:
    ///     `DownErrors` depending on the scenario.

    public init(frame: CGRect,
                markdownString: String,
                openLinksInBrowser: Bool = true,
                templateBundle: Bundle? = nil,
                writableBundle: Bool = false,
                configuration: WKWebViewConfiguration? = nil,
                options: DownOptions = .default,
                didLoadSuccessfully: DownViewClosure? = nil) throws {

        self.options = options
        self.didLoadSuccessfully = didLoadSuccessfully
        self.writableBundle = writableBundle

        if let templateBundle = templateBundle {
            self.bundle = templateBundle
        } else {
            let moduleBundle = Bundle.moduleBundle ?? Bundle(for: DownView.self)
            let url = moduleBundle.url(forResource: "DownView", withExtension: "bundle")!
            self.bundle = Bundle(url: url)!
        }

        super.init(frame: frame, configuration: configuration ?? WKWebViewConfiguration())

        #if os(macOS)
        setupMacEnvironment()
        #endif

        if openLinksInBrowser || didLoadSuccessfully != nil { navigationDelegate = self }
        try loadHTMLView(markdownString)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if os(macOS)
    deinit {
        clearTemporaryDirectory()
    }
    #endif

    // MARK: - API

    /// Renders the given CommonMark Markdown string into HTML and updates the DownView while keeping the style intact.
    ///
    /// - Parameters:
    ///     - markdownString: A string containing CommonMark Markdown.
    ///     - options: `DownOptions` to modify parsing or rendering, defaulting to `.default`.
    ///     - didLoadSuccessfully: Optional callback for when the web content has loaded successfully.
    ///
    /// - Throws:
    ///     `DownErrors` depending on the scenario.

    public func update(markdownString: String,
                       options: DownOptions? = nil,
                       didLoadSuccessfully: DownViewClosure? = nil) throws {

        // Note: As the init method sets this initially, we only overwrite them if
        // a non-nil value is passed in.
        if let options = options {
            self.options = options
        }

        if let didLoadSuccessfully = didLoadSuccessfully {
            self.didLoadSuccessfully = didLoadSuccessfully
        }

        try loadHTMLView(markdownString)
    }

    // MARK: - Private Properties

    let bundle: Bundle
    let writableBundle: Bool
    var options: DownOptions

    private lazy var baseURL: URL = {
        return self.bundle.url(forResource: "index", withExtension: "html")!
    }()

    #if os(macOS)
    private var temporaryDirectoryURL: URL?
    #endif

    private var didLoadSuccessfully: DownViewClosure?

}

// MARK: - Private API

private extension DownView {

    func loadHTMLView(_ markdownString: String) throws {
        let htmlString = try markdownString.toHTML(options)
        let pageHTMLString = try htmlFromTemplate(htmlString)

        #if os(iOS)
        if writableBundle {
            let newIndexUrl = try writeTempIndexFile(pageHTMLString: pageHTMLString)
            loadFileURL(newIndexUrl, allowingReadAccessTo: newIndexUrl.deletingLastPathComponent())
        } else {
            loadHTMLString(pageHTMLString, baseURL: baseURL)
        }
        #elseif os(macOS)
        let indexURL = try createTemporaryBundle(pageHTMLString: pageHTMLString)
        loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        #endif
    }

    func htmlFromTemplate(_ htmlString: String) throws -> String {
        let template = try String(contentsOf: baseURL, encoding: .utf8)
        return template.replacingOccurrences(of: "DOWN_HTML", with: htmlString)
    }

    #if os(iOS)
    func writeTempIndexFile(pageHTMLString: String) throws -> URL {
        let newIndexUrl = bundle.resourceURL!.appendingPathComponent("tmp_index.html")
        try pageHTMLString.write(to: newIndexUrl, atomically: true, encoding: .utf8)
        return newIndexUrl
    }
    #endif

    #if os(macOS)
    func createTemporaryBundle(pageHTMLString: String) throws -> URL {
        guard let bundleResourceURL = bundle.resourceURL else {
            throw DownErrors.nonStandardBundleFormatError
        }

        let fileManager = FileManager.default

        let temporaryDirectoryURL = try fileManager.url(for: .itemReplacementDirectory,
                                                        in: .userDomainMask,
                                                        appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                        create: true).appendingPathComponent("Down", isDirectory: true)

        self.temporaryDirectoryURL = temporaryDirectoryURL

        let indexURL = temporaryDirectoryURL.appendingPathComponent("index.html", isDirectory: false)

        // If updating markdown contents, no need to re-copy bundle.
        if !FileManager.default.fileExists(atPath: indexURL.path) {
            // Copy bundle resources to temporary location.
            try FileManager.default.copyItem(at: bundleResourceURL, to: temporaryDirectoryURL)
        }

        // Write generated index.html to temporary location.
        try pageHTMLString.write(to: indexURL, atomically: true, encoding: .utf8)

        return indexURL
    }

    func setupMacEnvironment() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(clearTemporaryDirectory),
                                               name: NSApplication.willTerminateNotification,
                                               object: nil)
    }

    @objc
    func clearTemporaryDirectory() {
        if let temporaryDirectoryURL = temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }
    #endif

}

// MARK: - WKNavigationDelegate

extension DownView: WKNavigationDelegate {

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else { return decisionHandler(.allow) }

        switch navigationAction.navigationType {
        case .linkActivated:
            if #available(iOS 11.0, macOS 10.13, *) {
                if let scheme = url.scheme, configuration.urlSchemeHandler(forURLScheme: scheme) != nil {
                    decisionHandler(.allow)
                    return
                }
            }

            // 判断 URL 协议是否是 http 或 https
//            if let scheme = url.scheme,scheme.lowercased() == "http" || scheme.lowercased() == "https" {
//                decisionHandler(.cancel)
//                // 如果是 http 或 https 协议，使用 SFSafariViewController 打开
//                let safariViewController = SFSafariViewController(url: url)
//                
//                // 获取当前的 ViewController 并展示 SFSafariViewController
//                if let viewController = self.viewController() {
//                    viewController.present(safariViewController, animated: true, completion: nil)
//                }
//            } else {
                // 如果是其他协议，使用 UIApplication.shared.open 来打开
            decisionHandler(.cancel)
                openURL(url: url)
//            }
        default:
            decisionHandler(.allow)
        }
    }

    @available(iOSApplicationExtension, unavailable)
    func openURL(url: URL) {
        #if os(iOS)
        if #available(iOS 10.0, *) {
                // iOS 10 及以上使用新方法
                UIApplication.shared.open(url, options: [:], completionHandler: { success in
                    if success {
                        print("URL successfully opened")
                    } else {
                        print("Failed to open URL")
                    }
                })
            } else {
                // iOS 9 及以下使用旧方法
                UIApplication.shared.openURL(url)
            }
        #elseif os(macOS)
            NSWorkspace.shared.open(url)
        #endif
    }

    func viewController() -> UIViewController? {
        var viewController: UIViewController? = nil
        var responder: UIResponder? = self
        while responder != nil {
            if let controller = responder as? UIViewController {
                viewController = controller
                break
            }
            responder = responder?.next
        }
        return viewController
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didLoadSuccessfully?()
    }

}

private extension WKNavigationDelegate {

    /// A wrapper for `UIApplication.shared.openURL` so that an empty default
    /// implementation is available in app extensions
    func openURL(url: URL) {}

}

#endif

#endif // !os(Linux)
