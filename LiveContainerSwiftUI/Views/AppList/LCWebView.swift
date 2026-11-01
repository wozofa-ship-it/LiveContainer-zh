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
    
    @State private var runAppAlert = YesNoHelper()
    @State private var runAppAlertMsg = ""
    
    @State private var installAppAlert = YesNoHelper()
    @State private var installAppAlertMsg = ""
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    var itmsServicesHandler: ((String) async -> Void)?
    
    init(url: Binding<URL>, isPresent: Binding<Bool>, itmsServicesHandler: ((String) async -> Void)? = nil) {
        self._webView = State(initialValue: WebView())
        self._url = url
        self._isPresent = isPresent
        self.itmsServicesHandler = itmsServicesHandler
    }
    
    var body: some View {
        
        VStack(spacing: 0) {
            HStack {
                HStack {
                    Button(action: {
                        webView.goBack()
                    }, label: {
                        Image(systemName: "chevron.backward")
                    })
                    
                    Button(action: {
                        webView.goForward()
                    }, label: {
                        Image(systemName: "chevron.forward")
                    }).padding(.horizontal)
                }
                
                Spacer()
                Text(pageTitle)
                    .lineLimit(1)
                Spacer()
                Button(action: {
                    webView.reload()
                }, label: {
                    Image(systemName: "arrow.clockwise")
                }).padding(.horizontal)
                Button(action: {
                    isPresent = false
                }, label: {
                    Text("lc.common.done".loc)
                })
                
            }
            .padding([.bottom, .horizontal])
            .background(Color(.systemGray6))
            .overlay(alignment: .bottomTrailing) {
                ProgressView(value: uiLoadStatus)
                    .opacity(loadStatus == 1.0 ? 0 : 1)
                    .scaleEffect(y: 0.5)
                    .offset(y: 1)
                    .onChange(of: loadStatus) { newValue in
                        if newValue > uiLoadStatus {
                            withAnimation(.easeIn(duration: 0.3)) {
                                uiLoadStatus = newValue
                            }
                        } else {
                            uiLoadStatus = newValue
                        }
                    }
                
            }
            webView
        }
        .onAppear(){
            webView.loadURL(url: url)
            if !didAppear {
                onViewAppear()
                didAppear = true
            }

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
    
    func onViewAppear() {
        let observer = WebViewLoadObserver(loadStatus: $loadStatus, webView: self.webView.webView)
        let webViewDelegate = WebViewDelegate(pageTitle: $pageTitle, errorShow: $errorShow, errorInfo: $errorInfo, urlSchemeHandler:onURLSchemeDetected, universalLinkHandler: onUniversalLinkDetected,)
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

class WebViewLoadObserver : NSObject {
    private var loadStatus: Binding<Double>
    private var webView: WKWebView
    
    init(loadStatus: Binding<Double>, webView: WKWebView) {
        self.loadStatus = loadStatus
        self.webView = webView
        super.init()
        self.webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil);
    }
    
    // 观察者先于 WKWebView 释放时必须先注销，否则后续进度回调会发给已释放的
    // 观察者而闪退；onViewAppear 多次调用产生多个观察者时，旧观察者释放同样
    // 走这里注销，不残留（webView 是强引用，释放时它一定还活着）。
    deinit {
        self.webView.removeObserver(self, forKeyPath: "estimatedProgress")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            loadStatus.wrappedValue = self.webView.estimatedProgress
        }
    }
    

}

class WebViewDelegate : NSObject,WKNavigationDelegate {
    private var pageTitle: Binding<String>
    private var errorShow: Binding<Bool>
    private var errorInfo: Binding<String>
    private var urlSchemeHandler: (URL) async -> Void
    private var universalLinkHandler: (URL , [String]) async -> Void // url, [String] of all apps that can open this web page
    var domainBundleIdDict : [String:[String]] = [:]
    
    init(pageTitle: Binding<String>, errorShow: Binding<Bool>, errorInfo: Binding<String>, urlSchemeHandler: @escaping (URL) async -> Void, universalLinkHandler: @escaping (URL , [String]) async -> Void) {
        self.pageTitle = pageTitle
        self.errorShow = errorShow
        self.errorInfo = errorInfo
        self.urlSchemeHandler = urlSchemeHandler
        self.universalLinkHandler = universalLinkHandler
        super.init()
    }
    
    func webView(_ webView: WKWebView,
                   decidePolicyFor navigationAction: WKNavigationAction,
                   decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler((WKNavigationActionPolicy)(rawValue: WKNavigationActionPolicy.allow.rawValue + 2)!)
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
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        self.errorInfo.wrappedValue = error.localizedDescription
        self.errorShow.wrappedValue = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
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
        let appleAppSiteAssociationURLs = [
            URL(string: "https://\(host)/apple-app-site-association")!,
            URL(string: "https://\(host)/.well-known/apple-app-site-association")!
            ]

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
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        
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

