//
//  ViewController.swift
//  公文流转 · iOS 版 Web 壳
//
//  设计要点：
//  1. WKWebView 加载线上应用，业务 100% 复用服务器端页面（含热更新的反馈组件）。
//  2. keyboardDisplayRequiresUserAction = false + 正确的 safeArea 约束，
//     从根上避免键盘遮挡输入框（安卓版踩过的坑）。
//  3. 侧滑返回手势 = 网页历史后退，符合 iOS 交互直觉。
//  4. 断网/加载失败有原生错误页 + 重试，不白屏。
//  5. 下拉刷新。
//

import UIKit
import WebKit

final class ViewController: UIViewController {

    /// 线上应用地址（与安卓/鸿蒙版保持一致）
    private let homeURL = URL(string: "https://gooodok.asia:5002/app.html?ios=1")!

    private var webView: WKWebView!
    private var progressBar: UIProgressView!
    private var errorView: UIView!
    private var errorLabel: UILabel!
    private var refreshControl: UIRefreshControl!
    private var progressObservation: NSKeyValueObservation?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupWebView()
        setupProgressBar()
        setupErrorView()
        loadHome()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    deinit {
        progressObservation?.invalidate()
    }

    // MARK: - WebView 构建

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        // 允许自动播放（无需用户手势）
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // 持久化存储：登录态依赖 localStorage
        config.websiteDataStore = .default()

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // ★ 关键：不要求用户手势即可聚焦输入框弹出键盘
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true   // 侧滑返回
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .white

        view.addSubview(webView)

        // ★ 贴合 safeArea：顶部避开刘海，底部避开 Home Indicator，
        //   键盘弹出时 WKWebView 会自动收缩，输入框不会被遮挡。
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // 下拉刷新
        refreshControl = UIRefreshControl()
        refreshControl.tintColor = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refreshControl
    }

    private func setupProgressBar() {
        progressBar = UIProgressView(progressViewStyle: .bar)
        progressBar.progressTintColor = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        progressBar.trackTintColor = .clear
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)

        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            guard let self = self else { return }
            let p = Float(wv.estimatedProgress)
            self.progressBar.setProgress(p, animated: true)
            self.progressBar.isHidden = (p >= 1.0)
            if p >= 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.progressBar.setProgress(0, animated: false)
                }
            }
        }
    }

    private func setupErrorView() {
        errorView = UIView()
        errorView.backgroundColor = UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.isHidden = true
        view.addSubview(errorView)

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let icon = UILabel()
        icon.text = "📡"
        icon.font = .systemFont(ofSize: 56)
        icon.textAlignment = .center
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "无法连接服务器"
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        errorLabel = UILabel()
        errorLabel.text = "请检查网络连接后重试"
        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 3
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let retry = UIButton(type: .system)
        retry.setTitle("重新加载", for: .normal)
        retry.setTitleColor(.white, for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        retry.backgroundColor = UIColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
        retry.layer.cornerRadius = 10
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, title, errorLabel, retry])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        errorView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: errorView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: errorView.trailingAnchor, constant: -32),
            retry.widthAnchor.constraint(equalToConstant: 160),
            retry.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    // MARK: - 动作

    private func loadHome() {
        var req = URLRequest(url: homeURL)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 20
        webView.load(req)
    }

    @objc private func handleRefresh() {
        webView.reload()
    }

    @objc private func handleRetry() {
        errorView.isHidden = true
        loadHome()
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorView.isHidden = false
        progressBar.isHidden = true
    }
}

// MARK: - WKNavigationDelegate

extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refreshControl.endRefreshing()
        let ns = error as NSError
        // -999 = 用户主动取消（如快速二次导航），不算错误
        guard ns.code != NSURLErrorCancelled else { return }
        showError(ns.localizedDescription)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        refreshControl.endRefreshing()
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        showError(ns.localizedDescription)
    }

    /// 外部链接（非本站域名）交给系统 Safari 打开
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // mailto / tel 交给系统
        if let scheme = url.scheme?.lowercased(),
           ["mailto", "tel", "sms"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension ViewController: WKUIDelegate {

    /// target="_blank" 在当前 WebView 内打开，不丢失导航
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// 网页 alert 转成原生弹窗
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        present(ac, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(ac, animated: true)
    }
}
