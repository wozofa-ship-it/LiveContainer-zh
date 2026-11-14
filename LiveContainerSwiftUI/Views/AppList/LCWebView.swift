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
    // 网页下载的非安装包文件（.ipa/.tipa 之外）：分享时用它，不用
    // 当前页 URL；点分享按钮时清掉（见 bottomBar）。
    @State private var shareFileURL: URL?
    // 3.8.506（L28）：分享 sheet 开着时又下完的非安装包文件，
    // 先排队——直接改 shareFileURL 会被 onDismiss 清掉，第二个
    // 既没分享、tmp 子目录又没人清（completion 只认创建时抓的
    // 那一个）。onDismiss 里按队弹出下一个再弹 sheet。
    @State private var pendingShareFileURLs: [URL] = []
    
    @StateObject private var runAppAlert = YesNoHelper()
    @State private var runAppAlertMsg = ""
    
    @StateObject private var installAppAlert = YesNoHelper()
    @State private var installAppAlertMsg = ""
    // 3.8.527（L54）：本次会话内已拒绝过的“用 App 打开”提示
    // 不再重复弹——拒绝记下来，命中就静默留网页。Universal
    // Link 按 (host, bundleID) 记，自定义 scheme 按 scheme 记；
    // 只记本次会话（@State），下次打开网页重新问。
    @State private var czfDeclinedUniversalLinks: Set<String> = []
    @State private var czfDeclinedSchemes: Set<String> = []
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @EnvironmentObject private var sharedModel : SharedModel
    @Environment(\.dismiss) private var dismiss

    private let navigationBarHeight: CGFloat = 60
    private let bottomBarHeight: CGFloat = 64
    
    var itmsServicesHandler: ((String) async -> Void)?
    // 网页里下的 .ipa/.tipa 文件：App 页传安装入口（installFromUrl，
    // 接 file:// URL 走本地安装路）。其余文件不走这里，走分享。
    var downloadedIPAHandler: ((URL) async -> Void)?
    
    // 恢复打开的网页：复用最小化时存下的 WebView，不重建、
    // 不重载（页面、滚动位置、登录态都在）。新开网页时为 false。
    private let isRestoredWebView: Bool

    init(url: Binding<URL>, isPresent: Binding<Bool>, itmsServicesHandler: ((String) async -> Void)? = nil, downloadedIPAHandler: ((URL) async -> Void)? = nil, existingWebView: WebView? = nil) {
        self._webView = State(initialValue: existingWebView ?? WebView())
        self.isRestoredWebView = existingWebView != nil
        self._url = url
        self._isPresent = isPresent
        self.itmsServicesHandler = itmsServicesHandler
        self.downloadedIPAHandler = downloadedIPAHandler
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
                // 恢复的网页不重载：WKWebView 里页面还在，重载会丢滚动位置。
                if !isRestoredWebView {
                    webView.loadURL(url: url)
                }
                // 恢复打开后，共享处的不再算“已最小化”，浮动按钮收掉。
                sharedModel.clearMinimizedWeb()
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            // 3.8.504（516 509 红修法）：onDismiss 原来写在尾随闭包
            // 后面，尾随闭包必须是最后一个参数，编译不过
            //（incorrect argument label）；改成放进括号里、内容闭包
            // 仍走尾随，语义不变。
            // 3.8.505（L27）：只清状态，删文件已移到上面
            // completion 里——onDismiss 删太早（见上）。
            shareFileURL = nil
            // 3.8.506（L28）：sheet 开着时又下完的排队文件，
            // 在这里弹出下一个再弹 sheet——直接清掉就永远没
            // 人分享它、tmp 子目录也漏了。onDismiss 里同步置
            // true 赶不上 sheet 的关闭收尾、再弹不出来，下一
            // 跳主线程再弹。网页本身已关（isPresent 为 false，
            // 如 .ipa 下完触发的 close）时不再弹，排队的不等
            // 分享了、直接清 tmp，免得漏。
            if !pendingShareFileURLs.isEmpty {
                if isPresent {
                    shareFileURL = pendingShareFileURLs.removeFirst()
                    DispatchQueue.main.async { showShareSheet = true }
                } else {
                    for pending in pendingShareFileURLs where pending.deletingLastPathComponent().lastPathComponent.hasPrefix("LCWebDownload-") {
                        try? FileManager.default.removeItem(at: pending.deletingLastPathComponent())
                    }
                    pendingShareFileURLs.removeAll()
                }
            }
        }) {
            // 刚下完的非安装包文件分享它自己；平时分享当前页。
            // 3.8.505（L27）：在内容闭包里当场抓住这次要分享的
            // 文件——onDownloadedFile 在 sheet 已开时再来一个下
            // 载会改 shareFileURL，onDismiss 读它会删错文件（删
            // 没分享的第二个、漏真正分享的第一个）；抓局部量只
            // 认创建时那一个，makeUIViewController 只调一次，
            // 后面 state 再变也不会换掉已建好的活动控制器。
            let fileToShare = shareFileURL
            ActivityViewController(activityItems: [fileToShare ?? currentURL]) { _, _, _, _ in
                // 3.8.505（L27）：非 .ipa 下载分享完后清掉本次下载
                // 独占的 tmp 子目录 LCWebDownload-<UUID>/（L24）。
                // 删的时机从 L26 的 onDismiss 移到这里：onDismiss
                // 在活动自带界面弹出来之前就触发，“存储到‘文件’”
                // （picker 在用户选好目的地后才拷源文件）与第三
                // 方分享扩展（扩展进程在 sheet 关掉后才读文件）
                // 那时还读不到文件，删了就分享失败；completion
                // 是活动真正结束的点，读完、关掉后才调。.ipa
                // 成功路 L25 在安装完清、失败路 L24 在 didFail
                // 里清，只剩分享这条路。只认 LCWebDownload-
                // 前缀；平时分享当前页时 fileToShare 是 nil，
                // 不删。取消也删——文件是刚下的、用户没留它，
                // 不留 tmp 残留。
                if let fileURL = fileToShare,
                   fileURL.deletingLastPathComponent().lastPathComponent.hasPrefix("LCWebDownload-") {
                    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                }
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
    
    private var currentURL: URL {
        pageURL ?? url
    }

    // 关网页：三条路一起走——isPresent=false 是绑定驱动的关，
    // dismiss() 是 UIKit 直关。客 App 在跑时网页是从宿主的
    // fullScreenCover 弹的，绑定那条路有时不生效（呈现方被
    // 客 App 的虚拟窗口盖在下面），只留一条就关不掉。
    // 3.8.462 两条路仍有关不掉的：SwiftUI 的 dismiss 在多窗口下
    // 也可能解析不到呈现。第三条直接走 UIKit：找前台 scene 里
    // 有已呈现控制器的窗口，沿 presentedViewController 走到最上层
    // 关掉。三条同指一个呈现，后面的都是空操作，不会重复关。
    // 关掉并丢弃：最小化存着的页面也清掉（不再恢复）。
    private func close() {
        sharedModel.clearMinimizedWeb()
        isPresent = false
        dismiss()
        czfDismissTopmostPresented()
    }

    // 最小化：把当前 WebView 与 URL 存到共享处（页面不销毁，
    // 滚动位置、登录态都在），再关弹窗。App 页上出现浮动按钮，
    // 点它即最大化（带着原页面回来）。只留一个最小化网页。
    private func minimize() {
        sharedModel.czfMinimizedWebView = webView
        sharedModel.czfMinimizedWebURL = currentURL
        isPresent = false
        dismiss()
        czfDismissTopmostPresented()
    }

    private func czfDismissTopmostPresented() {
        // 只关网页自己所在 window 那条链：原来遍历全部前台 scene、
        // 全部 window、关第一个已呈现 VC 就 return，多任务下客 App
        // 窗口或坞浮层先被遍历到就关错层，网页那层永远轮不到。
        // WKWebView 自带 window，装着弹窗的就是那扇窗。
        guard let window = webView.webView.window,
              let rootVC = window.rootViewController else { return }
        // 3.8.527（L54）：原来沿链走到最顶层、只关那一层——分享
        // sheet/alert 开着时关/最小化只关那层、网页本体留着。
        // 改从 rootVC 关整条呈现链：rootVC.dismiss 会把链上所有
        // 已呈现的控制器一起关掉；链上没东西时是空操作。
        if rootVC.presentedViewController != nil {
            rootVC.dismiss(animated: true)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .modifier(LCWebViewGlassBackground(shape: Circle()))
            }
            .contentShape(Circle())
            // 最小化：收起网页、页面不销毁，App 页浮动按钮点回即最大化。
            Button {
                minimize()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .modifier(LCWebViewGlassBackground(shape: Circle()))
            }
            .contentShape(Circle())

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
            .modifier(LCWebViewGlassBackground(shape: Circle()))
            .contentShape(Circle())

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
            .contentShape(Circle())
            .disabled(!canGoBack)

            Spacer(minLength: 0)
            Button(action: webView.goForward) {
                Image(systemName: "chevron.forward")
                    .frame(width: 44, height: 44)
            }
            .contentShape(Circle())
            .disabled(!canGoForward)

            Spacer(minLength: 0)
            Button {
                // 点分享按钮是分享当前页：清掉上次下载文件的残留。
                shareFileURL = nil
                showShareSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .contentShape(Circle())

            Spacer(minLength: 0)
            Button {
                UIApplication.shared.open(currentURL)
            } label: {
                Image(systemName: "safari")
                    .frame(width: 44, height: 44)
            }
            .contentShape(Circle())
            .disabled(!["http", "https"].contains(currentURL.scheme ?? ""))
        }
        .font(.system(size: 20))
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .modifier(LCWebViewGlassBackground(shape: Capsule()))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    func onViewAppear() {
        let observer = WebViewLoadObserver(loadStatus: $loadStatus, pageURL: $pageURL, canGoBack: $canGoBack, canGoForward: $canGoForward, isLoading: $isLoading, webView: webView.webView)
        let webViewDelegate = WebViewDelegate(pageTitle: $pageTitle, errorShow: $errorShow, errorInfo: $errorInfo, loadStatus: $loadStatus, urlSchemeHandler:onURLSchemeDetected, universalLinkHandler: onUniversalLinkDetected, downloadedFileHandler: onDownloadedFile)
        webView.setDelegate(delegete: webViewDelegate)
        webView.setObserver(observer: observer)
    }

    // 网页下载完成后的分流（WKDownloadDelegate 回调）：.ipa/.tipa
    // 走安装（与 itms-services 同款：先关网页再进安装队列——
    // 安装进度在 App 页上，盖着网页用户看不到）；其余文件弹分享，
    // 让用户自己存到“文件”或发给别的 App。
    func onDownloadedFile(url: URL) async {
        let ext = url.pathExtension.lowercased()
        if ext == "ipa" || ext == "tipa" {
            // 3.8.494（L13）：下载完才关网页——但只关“自己”：
            // 下载中途关掉网页后，保活的 delegate 还会跑到这里。
            // isPresent 是 App 页共用的 $webViewOpened 绑定，分
            // 不清是哪个网页，不能拿它判断；改按这份 WKWebView
            // 是否还在窗口里（window != nil 即当前正呈现，恢
            // 复打开后同一份 WKWebView 会重新进窗口），或它是
            // 当前最小化的那一个。已关掉的直接走安装，不再碰
            // 最小化状态，也别把用户其间新开的网页关掉。
            if webView.webView.window != nil || sharedModel.czfMinimizedWebView?.webView === webView.webView {
                close()
            }
            if let handler = downloadedIPAHandler {
                await handler(url)
            }
            return
        }
        // 3.8.506（L28）：sheet 已开着在分享上一个时，先排队——
        // 直接改 shareFileURL 会被 onDismiss 清掉，第二个既没分
        // 享、tmp 子目录又没人清（completion 只认创建时抓的那一
        // 个）。排队非空也进队：onDismiss 已弹出下一个、正等下
        // 一跳主线程再弹 sheet 的窗口里，新来的直接覆盖又会丢。
        // 3.8.507（L29）：那一跳窗口里排队已空、showShareSheet
        // 仍是 false，旧条件（只看 sheet/排队）会把又下完的一
        // 个走直接分支、盖掉 onDismiss 刚弹出的那一个：被盖的
        // 既没分享、tmp 子目录又没人清。shareFileURL 非 nil
        // 当且仅当下载分享 sheet 正开着或正等重弹：直接分支
        // 里它与 showShareSheet=true 在同一同步块；onDismiss
        // 里先置 nil、同一同步块内又换成下一个并已排好下一跳
        // 重弹，中间无挂起、别的任务插不进来。把它也算进排
        // 队条件；平时分享当前页时 shareFileURL 是 nil，不影响。
        if showShareSheet || shareFileURL != nil || !pendingShareFileURLs.isEmpty {
            pendingShareFileURLs.append(url)
        } else {
            shareFileURL = url
            showShareSheet = true
        }
    }

    func launchToApp(app: LCAppModel, url: URL) async {
        let bundleId = app.appInfo.relativeBundlePath!
        if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: app.uiDefaultDataFolder){
            let encodedUrl = Data(url.absoluteString.utf8).base64EncodedString()
            // L60-1：bundleId 是 .app 文件夹名、原样裸插——带空格时
            // URL(string:) 直接返 nil、交接静默跳过（只剩 runApp 里
            // 的 URLComponents 兜底）；带 & 时接收侧从 & 处切断。
            // 与其余交接 URL 同款走 czfQueryValueAllowed（排除 &）。
            let encodedBundleId = bundleId.addingPercentEncoding(withAllowedCharacters: .czfQueryValueAllowed) ?? bundleId
            if let urlToOpen = URL(string: "\(runningLC)://livecontainer-launch?bundle-name=\(encodedBundleId)&open-url=\(encodedUrl)"), UIApplication.shared.canOpenURL(urlToOpen) {
                NSLog("[LC] urlToOpen = \(urlToOpen.absoluteString)")
                await UIApplication.shared.open(urlToOpen)
                close()
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
        // 3.8.527（L54）：系统 scheme（mailto/tel/sms/facetime）
        // 原来走到下面按已装 App 的自定义 scheme 找，找不到就
        // 弹“打不开”假错——系统应用根本不在那张表里。先认白名
        // 单、直接外部打开；打不开（没装电话/邮件）才报真错。
        if let scheme = url.scheme?.lowercased(),
           ["mailto", "tel", "sms", "facetime"].contains(scheme) {
            if UIApplication.shared.canOpenURL(url) {
                await UIApplication.shared.open(url)
            } else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(url.scheme!)
                errorShow = true
            }
            return
        }
        var appToLaunch : LCAppModel? = nil
        var appListsToConsider = [sharedModel.apps]
        
        if url.scheme == "itms-services", let handler = itmsServicesHandler {
            installAppAlertMsg = "lc.webView.installAppDesc".loc
            
            if let doInstall = await installAppAlert.open(), !doInstall {
                return
            }
            close()
            Task { @MainActor in await handler(url.absoluteString) }
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
        
        // 3.8.527（L54）：本次会话内已拒绝过这个 scheme 的“用 App
        // 打开”，不再重复弹、静默留网页（见 czfDeclinedSchemes）。
        if let scheme = url.scheme, czfDeclinedSchemes.contains(scheme) {
            return
        }
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            if let scheme = url.scheme { czfDeclinedSchemes.insert(scheme) }
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
        // 3.8.527（L54）：本次会话内已拒绝过这个 (host, bundleID)
        // 的“用 App 打开”，不再重复弹、静默留网页（见
        // czfDeclinedUniversalLinks）。
        let czfDeclineKey = "\(url.host ?? "")|\(appToLaunch.appInfo.bundleIdentifier() ?? "")"
        if czfDeclinedUniversalLinks.contains(czfDeclineKey) {
            return
        }
        if let doRunApp = await runAppAlert.open(), !doRunApp {
            czfDeclinedUniversalLinks.insert(czfDeclineKey)
            return
        }
        await launchToApp(app: appToLaunch, url: url)
    }
}

// iOS 26 玻璃命中测试教训（用户真机 3.8.475 实证：X/— 点下去没反应）：
// ① .interactive() 的玻璃会把触摸自己吃掉，底下的 Button 收不到
// （模拟器鼠标点能穿透，真机拇指点不到）；② .buttonStyle(.plain)
// 的图标按钮没有 contentShape 时只认字形像素，不认玻璃圆。
// 所以玻璃一律不用 interactive（按钮自己响应触摸），每个图标按钮
// 再补与玻璃同形的 contentShape，整个 44pt 圆都能点。
private struct LCWebViewGlassBackground<S: Shape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
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

class WebViewDelegate : NSObject,WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    private var pageTitle: Binding<String>
    private var errorShow: Binding<Bool>
    private var errorInfo: Binding<String>
    private var loadStatus: Binding<Double>
    private var urlSchemeHandler: (URL) async -> Void
    private var universalLinkHandler: (URL , [String]) async -> Void // url, [String] of all apps that can open this web page
    private var downloadedFileHandler: (URL) async -> Void
    var domainBundleIdDict : [String:[String]] = [:]
    // 3.8.528（L55）：最近一次主 frame https 导航的 URL——L54
    // 用 webView.url 校验“用户已跳走就不再弹”是错的：decidePolicyFor
    // 时 webView.url 还是上一个已提交页面的 URL（新导航要到 didCommit
    // 才更新），association 已缓存时 loadDomainAssociations 立即返
    // 回、Task 在提交前就跑到 guard，webView.url != url 恒成立，
    // 重访已知站点时“用 App 打开”再也不弹。用本字段记最新导航，
    // 后一次 decidePolicyFor 会覆盖它，同样能拦住过期提示。
    private var czfLatestMainFrameURL: URL?
    // 进行中的下载各放哪个目的地：按下载对象分键——两次下载
    // 并行时单变量会被后一次盖掉，下完会拿错文件（装错包）。
    // 用 static 存：最小化再恢复时会新建 delegate（onViewAppear
    // 每次都建，为的是重新绑新视图的 @State）；下载中途最小化
    // 再恢复，新 delegate 也能找到旧下载的目的地，不会静默丢包。
    // 回调都在主线程跑，不用锁；decideDestinationUsing 每次都
    // 覆盖写入，旧条目不会被新下载误认。
    private static var downloadDestinations: [ObjectIdentifier: URL] = [:]
    // 3.8.494（L13）：进行中的下载要保住 WKWebView 与
    // delegate——网页关掉后 @State 的 WebView 结构体就释放，
    // WKWebView 跟着没了，下载会被 WebKit 静默取消（delegate
    // 也是 weak，downloadDestinations 的条目还会一直漏着）。
    // 最小化不走这里（WebView 存在 sharedModel 里）。下载
    // 完/失败即释放，不多留。
    private static var czfLiveWebViews: [ObjectIdentifier: WKWebView] = [:]
    private static var czfLiveDelegates: [ObjectIdentifier: WebViewDelegate] = [:]
    
    init(pageTitle: Binding<String>, errorShow: Binding<Bool>, errorInfo: Binding<String>, loadStatus: Binding<Double>, urlSchemeHandler: @escaping (URL) async -> Void, universalLinkHandler: @escaping (URL , [String]) async -> Void, downloadedFileHandler: @escaping (URL) async -> Void) {
        self.pageTitle = pageTitle
        self.errorShow = errorShow
        self.errorInfo = errorInfo
        self.loadStatus = loadStatus
        self.urlSchemeHandler = urlSchemeHandler
        self.universalLinkHandler = universalLinkHandler
        self.downloadedFileHandler = downloadedFileHandler
        super.init()
    }
    
    func webView(_ webView: WKWebView,
                   decidePolicyFor navigationAction: WKNavigationAction,
                   decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 原来传 rawValue 3（allow.rawValue + 2，公开枚举里没有）：
        // 当前 WebKit 把它当允许处理才没出事，换 SDK 可能变脸，
        // 直接写 .allow，行为不变、零成本。
        guard let url = navigationAction.request.url, let scheme = url.scheme else {
            decisionHandler(.allow)
            return
        }
        if(scheme == "https") {
            decisionHandler(.allow)
            // 3.8.528（L55）：L54 的 webView.url 校验改记最新导航
            // URL（见 czfLatestMainFrameURL 声明处注释）——
            // webView.url 在 decidePolicyFor 时还是旧页。
            guard navigationAction.targetFrame?.isMainFrame == true else { return }
            self.czfLatestMainFrameURL = url
            // 3.8.506（L28）：WebViewDelegate 不是 @MainActor，
            // 裸 Task 跑在全局执行器上——后面的 universalLink
            // 会写 @State（弹确认框、跳 App），离主线程可能
            // 丢更新；字典读也与 loadDomainAssociations 末尾
            // 的 MainActor.run 写竞态。整段放主 actor 上
            // （await 会挂起，不堵主线程；内层 Task 继承）。
            Task { @MainActor in
                await self.loadDomainAssociations(url: url)
                guard self.czfLatestMainFrameURL == url,
                      let host = url.host, let appIDs = self.domainBundleIdDict[host] else { return }
                await self.universalLinkHandler(url, appIDs)
            }
            return
        }
        if(scheme == "http" || scheme == "about") {
            decisionHandler(.allow)
            return;
        }
        // 3.8.527（L54）：itms-apps 原来放行、WKWebView 载不动
        // 报 -1002 假错——它和 itms-services 一样是跳 App Store
        // 的 scheme，得 cancel + 外部打开（打不开才报真错）。
        if scheme == "itms-apps" {
            decisionHandler(.cancel)
            Task { @MainActor in
                if UIApplication.shared.canOpenURL(url) {
                    await UIApplication.shared.open(url)
                } else {
                    self.errorInfo.wrappedValue = "lc.appList.schemeCannotOpenError %@".localizeWithFormat("itms-apps")
                    self.errorShow.wrappedValue = true
                }
            }
            return
        }
        // 自定义协议（weixin:// 等）WKWebView 载不了：放行会以
        // NSURLErrorUnsupportedURL（-1002）失败、再弹一个假错误框。
        // 直接 cancel（反正载不了），只走 urlSchemeHandler 跳 App。
        decisionHandler(.cancel)
        // 3.8.506（L28）：同上，urlSchemeHandler 会写 @State、
        // 弹确认框、调 close（），必须主线程。
        Task { @MainActor in await urlSchemeHandler(url) }

    }
    
    // 3.8.527（L54）：新导航开始不清旧标题——didFinish 才写新
    // 标题，导航中途顶栏还顶着上一个页面的标题。didCommit 时
    // 先清空，didFinish 再写新标题。
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        self.pageTitle.wrappedValue = ""
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

    // 3.8.527（L54）：原来没实现 webViewWebContentProcessDidTerminate——
    // Web 内容进程被系统杀掉（内存压力）后页面白屏、进度条也不动，
    // 只能手动点 ↻。进程死后 webView.url 还在，直接 reload 恢复
    // （WKWebView 会重建进程）；url 已空（还没载过页）时不 reload，
    // 免得白刷 about:blank。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView.url != nil {
            webView.reload()
        }
    }

    // 3.8.527（L54）：原来全文件无 WKUIDelegate——target=_blank
    // 点了没反应（没人接 createWebViewWith）、JS alert 被吞、
    // confirm 恒 false。WebViewDelegate 兼 WKUIDelegate：新窗口
    // 请求直接在本 WKWebView 内加载（不另开窗口）；三个 JS 面板
    // 用 UIAlertController 实现，completion 恰好调一次（无呈现
    // 方时走默认值、不挂起 JS）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func czfTopmostViewController(for webView: WKWebView) -> UIViewController? {
        guard var topVC = webView.window?.rootViewController else { return nil }
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let topVC = czfTopmostViewController(for: webView) else {
            completionHandler()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default) { _ in completionHandler() })
        topVC.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let topVC = czfTopmostViewController(for: webView) else {
            completionHandler(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default) { _ in completionHandler(true) })
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { _ in completionHandler(false) })
        topVC.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let topVC = czfTopmostViewController(for: webView) else {
            completionHandler(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = defaultText
        }
        alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        alert.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { _ in completionHandler(nil) })
        topVC.present(alert, animated: true)
    }

    // 网页里的文件直链（.ipa 等二进制）原来没有下载路：导航
    // 放行后 WebKit 载不动，didFail 只弹一个错，用户看到的就
    // 是“文件加载失败”。iOS 14.5+ 有 WKDownloadDelegate（部署
    // 目标 15，不用 #available）：WebKit 显示不了的类型改走
    // .download，下完按类型分流（见 downloadDidFinish）。
    func webView(_ webView: WKWebView,
                   decidePolicyFor navigationResponse: WKNavigationResponse,
                   decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    // WKWebView 没有 downloadDelegate 成员，下载的 delegate 在
    // 这里接：decisionHandler(.download) 后 WebKit 建 WKDownload，
    // 经 didBecome 交出来，挂上 self 才收到后面的三个回调。
    // 响应路与动作路各一处（一个下载只走其中一条，重复挂同一
    // 对象无害）。iOS 14.5+，部署目标 15，不用 #available。
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        // 3.8.494（L13）：保住 WKWebView 与 delegate（见上面注释）。
        Self.czfLiveWebViews[ObjectIdentifier(download)] = webView
        Self.czfLiveDelegates[ObjectIdentifier(download)] = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        Self.czfLiveWebViews[ObjectIdentifier(download)] = webView
        Self.czfLiveDelegates[ObjectIdentifier(download)] = self
    }

    // WKDownloadDelegate 的方法名是 download(...)，不是
    // webView(_:download:...)——之前写错了名字，编译器报不
    // conform；回调参数叫 completionHandler，不是 decisionHandler。
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // 建议文件名只留最后一段（Content-Disposition 里可能
        // 带路径）；空名给个默认名；同名文件先清掉再写（与
        // installFromUrl 落盘同款），免得撞上残留。
        var name = (suggestedFilename as NSString).lastPathComponent
        // 3.8.527（L54）：lastPathComponent 后仍可能剩 ".." / "."
        // / "/"（建议文件名本身就是这几个时），拼进 dest 会越出
        // 本次下载的独占子目录、写到 tmp 根上甚至父目录。直接
        // fallback 默认名。
        if name.isEmpty || name == ".." || name == "." || name == "/" {
            name = "download"
        }
        // 3.8.502（L24）：同名文件两次并行下载会撞同一个 tmp 目标——
        // 后开始的 decideDestination 先删掉先下载的半截文件，先下载的
        // 继续往已解链的 inode 写，finish 时读到的却是后者的文件，
        // 装/分享错文件。每个下载单独一个 tmp 子目录，文件名保持原样。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LCWebDownload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        Self.downloadDestinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        // 3.8.494（L13）：先释放保住的 WebView 与 delegate——
        // 即使目的地条目丢了（decideDestinationUsing 没跑到），
        // 也不让 static 一直漏着。
        let key = ObjectIdentifier(download)
        Self.czfLiveWebViews.removeValue(forKey: key)
        Self.czfLiveDelegates.removeValue(forKey: key)
        guard let dest = Self.downloadDestinations.removeValue(forKey: key) else { return }
        // 3.8.506（L28）：WebViewDelegate 不是 @MainActor，裸
        // Task 跑在全局执行器上——onDownloadedFile 写 @State
        //（shareFileURL、showShareSheet）、调 close（）（改
        // Binding + UIKit dismiss），离主线程可能丢更新：分享
        // sheet 偶发弹不出来、还报“Publishing changes from
        // background threads”。放主 actor 上。
        Task { @MainActor in await self.downloadedFileHandler(dest) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        Self.czfLiveWebViews.removeValue(forKey: key)
        Self.czfLiveDelegates.removeValue(forKey: key)
        if let dest = Self.downloadDestinations.removeValue(forKey: key) {
            // 3.8.502（L24）：dest 在本次下载独占的 tmp 子目录里，删整个目录
            //（半截文件 + 空目录一起清，与旧的“删文件”同款效果）。
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
        }
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
                        // 3.8.527（L54）：association 请求原来走
                        // URLSession 默认 60 秒超时，用户白等；
                        // 改 10 秒（association 只是 best-effort，
                        // 拉不到就当没有、不弹错）。
                        var request = URLRequest(url: siteAssociationURL)
                        request.timeoutInterval = 10
                        let task = URLSession.shared.dataTask(with: request) { data, response, error in
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
    
    mutating func setDelegate(delegete: WebViewDelegate) {
        self.delegate = delegete
        self.webView.navigationDelegate = delegete
        // 3.8.527 修 533：原来这里是 `delegete as? WKUIDelegate`
        //（delegete 是 WKNavigationDelegate 存在类型），Swift 6.2.3
        // 编译器在 OwnershipModelEliminator 直接崩掉（SIL verification
        // failed，533 两次 Archive exit 65、日志 0 条红字就是它，修法
        // 构建的 archive-raw-log artifact 里有原文）；唯一调用方传的
        // 就是 WebViewDelegate（兼 WKUIDelegate），参数直接收具体类，
        // 两处赋值都是静态上转型，不再有条件转型。
        self.webView.uiDelegate = delegete
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

