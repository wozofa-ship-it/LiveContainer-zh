//
//  SwiftUIView.swift
//
//  Created by s s on 2024/8/23.
//

import SwiftUI
@preconcurrency import WebKit

struct LCWebView: View {
    @State private var webView : WebView
    @State private var didAppear = false
    
    @Binding var url : URL
    @Binding var isPresent: Bool
    @State private var loadStatus = 0.0
    @State private var uiLoadStatus = 0.0
    @State private var pageTitle = ""
    @State private var pageURL: URL?
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var showShareSheet = false
    
    @State private var runAppAlert = YesNoHelper()
    @State private var runAppAlertMsg = ""
    
    @State private var installAppAlert = YesNoHelper()
    @State private var installAppAlertMsg = ""
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @EnvironmentObject private var sharedModel : SharedModel

    private let navigationBarHeight: CGFloat = 60
    private let bottomBarHeight: CGFloat = 64
    
    var itmsServicesHandler: ((String) async -> Void)?
    
    init(url: Binding<URL>, isPresent: Binding<Bool>, itmsServicesHandler: ((String) async -> Void)? = nil) {
        self._webView = State(initialValue: WebView())
        self._url = url
        self._isPresent = isPresent
        self.itmsServicesHandler = itmsServicesHandler
    }
    
    var body: some View {
        
        GeometryReader { geometry in
            ZStack {
                // Extend the web view itself under the bars and the home indicator.
                // Scroll insets keep the first and last page content reachable.
                webView.withContentInsets(UIEdgeInsets(
                    top: geometry.safeAreaInsets.top + navigationBarHeight,
                    left: geometry.safeAreaInsets.leading,
                    bottom: geometry.safeAreaInsets.bottom + bottomBarHeight,
                    right: geometry.safeAreaInsets.trailing
                ))
                .ignoresSafeArea(.container)

                VStack(spacing: 0) {
                    navigationBar
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(.systemBackground))
        .onAppear {
            // 只在首次出现时载入初始页（仿 didAppear 守卫）：原来
            // 每次出现都 loadURL，页内进二级页面后切后台再回、
            // 或经外链跳 App 再回，都会回到初始 URL、导航白走。
            // url 是本视图的固定初始页，换页由页内导航/外链处理，
            // 不在这里重载。
            if !didAppear {
                onViewAppear()
                didAppear = true
                webView.loadURL(url: url)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityViewController(activityItems: [currentURL])
        }
        .alert("lc.webView.runApp".loc, isPresented: $runAppAlert.show) {
            Button("lc.appBanner.run".loc, action: {
                runAppAlert.close(result: true)
            })
            Button("lc.common.cancel".loc, role: .cancel, action: {
                runAppAlert.close(result: false)
            })
        } message: {
            Text(runAppAlertMsg)
        }
        .alert("lc.webView.installApp".loc, isPresented: $installAppAlert.show) {
            Button("lc.common.install".loc, action: {
                installAppAlert.close(result: true)
            })
            Button("lc.common.cancel".loc, role: .cancel, action: {
                installAppAlert.close(result: false)
            })
        } message: {
            Text(installAppAlertMsg)
        }
        
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(errorInfo)
        }
        
    }
    
    private var currentURL: URL {
        pageURL ?? url
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                isPresent = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .modifier(LCWebViewGlassBackground(shape: Circle(), isInteractive: true))
            }

            VStack(spacing: 3) {
                Text(pageTitle.isEmpty ? (currentURL.host ?? currentURL.absoluteString) : pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 4) {
                    if currentURL.scheme == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                    }
                    Text(currentURL.host ?? currentURL.absoluteString)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .padding(.horizontal, 12)
            .modifier(LCWebViewGlassBackground(shape: Capsule()))
            Button {
                if isLoading {
                    webView.webView.stopLoading()
                } else {
                    webView.reload()
                }
            } label: {
                if isLoading {
                    Image(systemName: "xmark")
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.system(size: 20, weight: .medium))
            .frame(width: 44, height: 44)
            .modifier(LCWebViewGlassBackground(shape: Circle(), isInteractive: true))

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            ProgressView(value: uiLoadStatus)
                .progressViewStyle(.linear)
                .opacity(isLoading ? 1 : 0)
                .scaleEffect(y: 0.5, anchor: .bottom)
                .allowsHitTesting(false)
        }
        .onChange(of: loadStatus) { newValue in
            if newValue > uiLoadStatus {
                withAnimation(.easeInOut(duration: 0.2)) {
                    uiLoadStatus = newValue
                }
            } else {
                uiLoadStatus = newValue
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Button(action: webView.goBack) {
                Image(systemName: "chevron.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!canGoBack)

            Spacer(minLength: 0)
            Button(action: webView.goForward) {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!canGoForward)

            Spacer(minLength: 0)
            Button {
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }

            Spacer(minLength: 0)
            Button {
                UIApplication.shared.open(currentURL)
            } label: {
                Image(systemName: "safari")
                    .frame(width: 44, height: 44)
            }
            .disabled(!["http", "https"].contains(currentURL.scheme ?? ""))
        }
        .font(.system(size: 20))
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .modifier(LCWebViewGlassBackground(shape: Capsule(), isInteractive: true))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    func onViewAppear() {
        let observer = WebViewLoadObserver(loadStatus: $loadStatus, pageURL: $pageURL, canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, webView: webView.webView)
        let webViewDelegate = WebViewDelegate(pageTitle: $pageTitle, errorShow: $errorShow, errorInfo: $errorInfo, loadStatus: $loadStatus, urlSchemeHandler:onURLSchemeDetected, universalLinkHandler: onUniversalLinkDetected,)
        webView.setDelegate(delegete: webViewDelegate)
        webView.setObserver(observer: observer)
    }

    func launchToApp(app: LCAppModel, url: URL) async {
        let bundleId = app.appInfo.relativeBundlePath!
        if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: app.uiDefaultDataFolder){
            let encodedUrl = Data(url.absoluteString.utf8).base64EncodedString()
            if let urlToOpen = URL(string: "\(runningLC)://livecontainer-launch?bundle-name=\(bundleId)&open-url=\(encodedUrl)"), UIApplication.shared.canOpenURL(urlToOpen) {
                NSLog("[LC] urlToOpen = \(urlToOpen.absoluteString)")
                await UIApplication.shared.open(urlToOpen)
                isPresent = false
                return
            }

        }
        
        do {
            try await app.runApp(urlStr: url.absoluteString)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    public func onURLSchemeDetected(url: URL) async {
        var appToLaunch : LCAppModel? = nil
        var appListsToConsider = [sharedModel.apps]
        
        if url.scheme == "itms-services", let handler = itmsServicesHandler {
            installAppAlertMsg = "lc.webView.installAppDesc"
            
            if let doInstall = await installAppAlert.open(), !doInstall {
                return
            }
            isPresent = false
            Task { await handler(url.absoluteString) }
            return
        }
        
        if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            appListsToConsider.append(sharedModel.hiddenApps)
        }
        appLoop:
        for appList in appListsToConsider {
            for app in appList {
                if let schemes = app.appInfo.urlSchemes() {
                    for scheme in schemes {
                        if let scheme = scheme as? String, scheme == url.scheme {
                            appToLaunch = app
                            break appLoop
                        }
                    }
                }
            }
        }
    
        
        guard let appToLaunch = appToLaunch else {
            errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(url.scheme!)
            errorShow = true
            return
        }
        
        if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        runAppAlertMsg = "lc.webView.pageLaunch %@".localizeWithFormat(appToLaunch.appInfo.displayName()!)
        
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            return
        }
        
        await launchToApp(app: appToLaunch, url: url)
        
    }
    
    public func onUniversalLinkDetected(url: URL, bundleIDs: [String]) async {
        var bundleIDToAppDict: [String: LCAppModel] = [:]
        for app in sharedModel.apps {
            bundleIDToAppDict[app.appInfo.bundleIdentifier()!] = app
        }
        if !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") || sharedModel.isHiddenAppUnlocked {
            for app in sharedModel.hiddenApps {
                bundleIDToAppDict[app.appInfo.bundleIdentifier()!] = app
            }
        }
        
        var appToLaunch: LCAppModel? = nil
        for bundleID in bundleIDs {
            if let app = bundleIDToAppDict[bundleID] {
                appToLaunch = app
                break
            }
        }
        guard let appToLaunch = appToLaunch else {
            return
        }
        
        if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        runAppAlertMsg = "lc.webView.pageCanBeOpenIn %@".localizeWithFormat(appToLaunch.appInfo.displayName()!)
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            return
        }
        await launchToApp(app: appToLaunch, url: url)
    }
}

private struct LCWebViewGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    var isInteractive = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(isInteractive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

class WebViewLoadObserver: NSObject {
    private var observations: [NSKeyValueObservation] = []

    init(loadStatus: Binding<Double>, pageURL: Binding<URL?>, canGoBack: Binding<Bool>, canGoForward: Binding<Bool>, isLoading: Binding<Bool>, webView: WKWebView) {
        super.init()
        observations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { webView, _ in
                loadStatus.wrappedValue = webView.estimatedProgress
            },
            webView.observe(\.url, options: [.initial, .new]) { webView, _ in
                pageURL.wrappedValue = webView.url
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { webView, _ in
                canGoBack.wrappedValue = webView.canGoBack
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { webView, _ in
                canGoForward.wrappedValue = webView.canGoForward
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { webView, _ in
                isLoading.wrappedValue = webView.isLoading
            }
        ]
    }
}

class WebViewDelegate : NSObject,WKNavigationDelegate {
    private var pageTitle: Binding<String>
    private var errorShow: Binding<Bool>
    private var errorInfo: Binding<String>
    private var loadStatus: Binding<Double>
    private var urlSchemeHandler: (URL) async -> Void
    private var universalLinkHandler: (URL , [String]) async -> Void // url, [String] of all apps that can open this web page
    var domainBundleIdDict : [String:[String]] = [:]
    
    init(pageTitle: Binding<String>, errorShow: Binding<Bool>, errorInfo: Binding<String>, loadStatus: Binding<Double>, urlSchemeHandler: @escaping (URL) async -> Void, universalLinkHandler: @escaping (URL , [String]) async -> Void) {
        self.pageTitle = pageTitle
        self.errorShow = errorShow
        self.errorInfo = errorInfo
        self.loadStatus = loadStatus
        self.urlSchemeHandler = urlSchemeHandler
        self.universalLinkHandler = universalLinkHandler
        super.init()
    }
    
    func webView(_ webView: WKWebView,
                   decidePolicyFor navigationAction: WKNavigationAction,
                   decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 原来传 rawValue 3（allow.rawValue + 2，公开枚举里没有）：
        // 当前 WebKit 把它当允许处理才没出事，换 SDK 可能变脸，
        // 直接写 .allow，行为不变、零成本。
        decisionHandler(.allow)
        guard let url = navigationAction.request.url, let scheme = navigationAction.request.url?.scheme else {
            return
        }
        if(scheme == "https") {
            Task {
                await self.loadDomainAssociations(url: url)
                if let host = url.host, let appIDs = self.domainBundleIdDict[host] {
                    Task{ await self.universalLinkHandler(url, appIDs) }
                }
            }
            return
        }
        if(scheme == "http" || scheme == "about" || scheme == "itms-apps") {
            return;
        }
        Task{ await urlSchemeHandler(url) }

    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WKWebView.title 是 String?，无标题页（空白页、纯文件页）
        // 时为 nil，强解包直接闪退。
        self.pageTitle.wrappedValue = webView.title ?? ""
    }
    
    // 导航失败（断网、DNS 失败、证书错误等）原来没有任何处理，页面空白、
    // 进度条停住；这里走现有 errorShow/errorInfo 通道弹错，重新加载走
    // 顶栏已有的 ↻ 按钮。用户主动取消（如点外链跳 App 时中断加载）不弹错。
    // 失败/取消都把 loadStatus 置 1.0：进度条显隐条件是 loadStatus == 1.0
    // 才隐藏，不重置就一直悬停到下一次成功加载；新导航的进度 KVO 会
    // 重新驱动 loadStatus，不会被这次置位卡住。
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.loadStatus.wrappedValue = 1.0
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.errorInfo.wrappedValue = error.localizedDescription
        self.errorShow.wrappedValue = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.loadStatus.wrappedValue = 1.0
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.errorInfo.wrappedValue = error.localizedDescription
        self.errorShow.wrappedValue = true
    }

    
    func loadDomainAssociations(url: URL) async {
        if url.scheme != "https" || url.host == nil {
            return
        }
        if self.domainBundleIdDict[url.host!] != nil {
            return
        }
        guard let host = url.host else {
            return
        }
        
        // download and read apple-app-site-association
        // host 直接拼字符串在 IPv6 字面量时会拼出 nil 而强解包闪退
        //（url.host 返回去括号的 ::1，"https://::1/..." 不是合法 URL）；
        // 走 URLComponents（host 字段会正确加方括号），拼不出就跳过
        // ——association 只是 best-effort，不值得为它闪退。
        func associationURL(path: String) -> URL? {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = path
            return comps.url
        }
        guard let firstURL = associationURL(path: "/apple-app-site-association"),
              let secondURL = associationURL(path: "/.well-known/apple-app-site-association") else {
            return
        }
        let appleAppSiteAssociationURLs = [firstURL, secondURL]

        // 两份 association 文件并发拉取，各任务只返回自己的 ID，
        // 不在任务内写字典：原来每个任务先 dict[host] = [] 再
        // append，后完成的会清空先完成的，还并发改同一个字典。
        let mergedIDs = await withTaskGroup(of: [String].self) { group in
            for siteAssociationURL in appleAppSiteAssociationURLs {
                group.addTask {
                    await withUnsafeContinuation { c in
                        let task = URLSession.shared.dataTask(with: siteAssociationURL) { data, response, error in
                            do {
                                guard let data = data else {
                                    c.resume(returning: [])
                                    return
                                }
                                let siteAssociationObj = try JSONDecoder().decode(SiteAssociation.self, from: data)
                                guard let detailItems = siteAssociationObj.applinks?.details else {
                                    c.resume(returning: [])
                                    return
                                }
                                var ids: [String] = []
                                for item in detailItems {
                                    ids.append(contentsOf: item.getBundleIds())
                                }
                                c.resume(returning: ids)
                            } catch {
                                c.resume(returning: [])
                            }
                        }
                        task.resume()
                    }
                }
            }
            var merged: [String] = []
            for await ids in group {
                merged.append(contentsOf: ids)
            }
            return merged
        }
        // WebViewDelegate 不是 @MainActor，字典合并放主 actor 上，
        // 不在并发任务里碰它。只缓存非空结果：两份都拉不到时
        // 保持 nil，下次导航仍会重试，与原来语义一致。
        await MainActor.run {
            if !mergedIDs.isEmpty {
                self.domainBundleIdDict[host] = mergedIDs
            }
        }

    }
}

struct WebView: UIViewRepresentable {
    
    let webView: WKWebView
    var observer: WebViewLoadObserver?
    var delegate: WKNavigationDelegate?
    private var contentInsets: UIEdgeInsets = .zero
    
    init() {
        self.webView = WKWebView()
    }
    
    mutating func setDelegate(delegete: WKNavigationDelegate) {
        self.delegate = delegete
        self.webView.navigationDelegate = delegete
    }
    
    mutating func setObserver(observer: WebViewLoadObserver) {
        self.observer = observer
    }
    
    func makeUIView(context: Context) -> WKWebView {
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let scrollView = uiView.scrollView
        guard scrollView.contentInset != contentInsets else {
            return
        }
        let isAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top
        scrollView.contentInset = contentInsets
        scrollView.scrollIndicatorInsets = contentInsets
        if isAtTop {
            scrollView.contentOffset.y = -contentInsets.top
        }
    }

    func withContentInsets(_ insets: UIEdgeInsets) -> WebView {
        var view = self
        view.contentInsets = insets
        return view
    }
    
    func reload() {
        webView.reload()
    }
    
    func goBack(){
        webView.goBack()
    }
    
    func goForward(){
        webView.goForward()
    }
    
    
    func loadURL(url: URL) {
        webView.load(URLRequest(url: url))
    }
    

}

