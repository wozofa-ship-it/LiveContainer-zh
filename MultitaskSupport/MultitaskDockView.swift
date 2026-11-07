//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import ObjectiveC

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    // C4：条目创建时间（=窗口创建时间）——客进程已死的 stale
    // 窗只清 30 秒以上的，刚建窗、pid 还没落位时不误清。
    let czfAppearedAt = Date()
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// C6：多任务窗口出现信号——dock 条目追加时发，smallWindow
// 的建窗回调与串行门都认它（与 smallWindow 旧轮询同一信号）。
extension Notification.Name {
    static let czfMultitaskWindowAppeared = Notification.Name("CZFMultitaskWindowAppeared")
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var settingsChanged: Bool = false
    // （旧直连通道，已弃用：面板改走 presentAllAppsPanel 的 UIKit 呈现。
    //  属性保留是因为栏视图还挂着 onChange 引用，删它要动视图修饰链。）
    @Published var czfPanelOpenCounter: Int = 0
    // 源面板每次调出时 +1，面板视图据此刷新源数据（覆盖层常驻，onAppear 只来一次）
    @Published var czfSourcesPanelOpenCounter: Int = 0
    // App 面板每次调出时 +1，面板视图据此滚回顶部（每次调出都是初始状态，用户定）
    @Published var czfAppPanelOpenCounter: Int = 0
    // 手势面板覆盖层（背景遮罩 + 面板宿主）：只建一次常驻窗口待命，
    // 开/关只切可见性和位置；开没开以面板视图的 isHidden 为准，不以引用为准
    // 定时最小化打开的轮询定时器（30 秒一轮，只在宿主活着时跑）
    private var czfSchedMinTimer: Timer?
    // 定时打开当天豁免名单：定时拉起的窗口当天不算自动关、
    // 也不触发上限弹框，否则定时打开一最小化就进自动关
    // 计时、满 3 个时还弹框等人点，定时执行就卡住。
    // 只记当天（yyyyMMdd），次日检查时清掉重算：当天叫回
    // 再最小化仍豁免，次日恢复正常，不用在每个恢复入口
    // 逐个清标记；关窗后 uuid 不在运行列表，豁免自然失效。
    private var czfSchedMinOpenedDay: String?
    private var czfSchedMinOpenedUUIDs: Set<String> = []
    // 最小化超 30 分钟自动关（CZF）：60 秒一轮，只在宿主活着时跑；
    // 宿主被彻底关掉时不跑，下次打开时运行中列表是空的，无需补查。
    // 键为 appUUID（多开同 App 不同容器各算各的），值是首次看到
    // 它已最小化的时间；恢复可见、关窗、画中画、开关关时清掉。
    private var czfMinAutoCloseTimer: Timer?
    private var czfMinimizedSince: [String: Date] = [:]
    // 同时运行上限（CZF）：3 个，第 4 个窗口注册时弹确认，
    // 防连续注册时弹框叠加，只弹一个。
    private var czfCapAlertShowing = false
    private var czfPanelOverlayBackdrop: UIView?
    private var czfPanelOverlayHost: UIHostingController<AnyView>?
    // 源面板覆盖层：与 App 面板同构，各自一套遮罩+宿主，互开时先关对方
    private var czfSourcesOverlayBackdrop: UIView?
    private var czfSourcesOverlayHost: UIHostingController<AnyView>?
    // 键盘高度（CZF）：面板搜索框获焦弹键盘时，键盘会盖住面板下半截
    // （搜索框与列表被挡住，键盘还收不掉）。记下当前键盘高度，面板
    // 打开位置按它上移；键盘收起归零。3.8.296 修“点搜索面板收了键
    // 盘没收”bug。
    private var czfKeyboardHeight: CGFloat = 0
    private var czfKeyboardObserversAdded = false

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        static let iconToWidthRatio: CGFloat = 0.75
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction
        // 完全隐藏：偏移量 = 整条栏宽度 + 4，整条滑出屏幕不留边
        static var dockHiddenOffset: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans + 4
                } else {
                    return defaultDockWidth + 4
                }
            }
        }
        static var hideGestureThreshold: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans / 5
                } else {
                    return 16
                }
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0
        
        static let standardAnimationDuration: TimeInterval = 0.2
        static let longAnimationDuration: TimeInterval = 0.3
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let buttonSize = calculateButtonSize(for: userWidth)
            let baseHeight = expandedDockBaseHeight(for: userWidth, buttonSize: buttonSize)
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    private func expandedDockBaseHeight(for width: CGFloat, buttonSize: CGFloat) -> CGFloat {
        let spacingCount = max(self.apps.count + 1, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + buttonSize * 2 + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        let baseHeight = expandedDockBaseHeight(for: width, buttonSize: buttonSize)
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        keyWindow!.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
    
    /// 窗口宿主视图的挂载重试计数（见 attachWindowHostingViewWhenReady）
    private var windowAttachRetries = 0

    override init() {
        super.init()
        Self.deployDockGestureTweak()
        registerDockEdgeDarwinObservers()
        startScheduledMinimizeOpenTimer()
        startMinAutoCloseTimer()
        attachWindowHostingViewWhenReady()
        setupDockView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        // 宿主主界面（App 页）手势不灵的根因：全局滑动识别器只在
        // updateDockFrame 里装，而宿主主界面从不显示快捷栏，那条
        // 路一次都不跑，识别器从没装上（LCTabView 注释称 init 里
        // 装配是错的，init 里只有 Darwin 监听）。init 里直接装：
        // 当前窗口立刻装上，窗口/场景监听也随之建立，后来的窗口
        // 自动补装；游客进程里 updateDockFrame 本来就会装，本处
        // 按窗口去重，不会重复装。
        setupGlobalSwipeRecognizer()
    }
    
    /// 把窗口宿主视图挂到根视图的第一个子视图上（挂载目标与
    /// 原实现一致）。原实现是同步三重强解包
    /// keyWindow!.rootViewController!.view.subviews.first!：
    /// 管理器以前只在打开第一个游客 App 时才建、那时窗口层级
    /// 早已齐全；改为 LiveContainer 主界面出现时提前建后
    /// （任意位置调面板），init 发生在首帧渲染求值中，层级
    /// 还没建好，强解包当场陷阱闪退（2026-10-23 21:16 日志
    /// 符号化实证：LCTabView.body → shared 初始化 → 本 init）。
    /// 改成就绪才挂、没就绪 0.1 秒重试（上限 50 次约 5 秒），
    /// 齐了仍挂同一位置，行为与原来一致
    private func attachWindowHostingViewWhenReady() {
        if let hostView = keyWindow?.rootViewController?.view.subviews.first {
            hostView.addSubview(self.windowHostingView)
            return
        }
        windowAttachRetries += 1
        guard windowAttachRetries <= 50 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachWindowHostingViewWhenReady()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
            // 刚打开隐藏快捷栏：正在显示的栏立刻收掉（不是只拦下次弹出）；
            // 再关掉开关：有在跑的 App 就立刻把栏请回来（不然开关看着像坏了）
            if LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") {
                if self.isVisible {
                    self.hideDock()
                }
            } else if !self.apps.isEmpty && !self.isVisible {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
            // 预建手势面板覆盖层：常驻窗口待命，左滑时不再现建视图树
            if let window = self.keyWindow {
                self.ensurePanelOverlay(in: window)
            }
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController else { return }
        setupGlobalSwipeRecognizer()

        let screenBounds = keyWindow!.bounds
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX(isDockHidden: self.isDockHidden, 
                                    isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)
        
        applyNewFrame(newFrame, for: hostingController, animated: animated)
        // 隐藏折叠 Dock 开着且栏已折叠：整个宿主视图藏掉
        // （isHidden 才真不挡边缘手势，光透明还占着触摸区）
        hostingController.view.isHidden = LCUtils.appGroupUserDefault.bool(forKey: "LCHideCollapsedDock") && isCollapsed
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }
            
            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }
        
        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            if let bid = self.apps.first(where: { $0.appUUID == appUUID })?.appInfo?.bundleIdentifier() {
                self.czfUnregisterTouchRaiseObserver(bundleId: bid)
            }
            self.apps.removeAll { $0.appUUID == appUUID }

            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }

            // 单 App VPN 核心自动停：还在跑的 App 里没有被标记
            // 的了，通知管理器排队停核心（它内部有防抖）
            let stillHasFlagged = self.apps.contains { app in
                guard let info = app.appInfo else { return false }
                return CZFVPNManager.isEnabled(for: info)
            }
            CZFVPNManager.shared.noteRunningAppsChanged(stillHasFlagged: stillHasFlagged)
            CZFHostKeepAlive.shared.refresh()
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
        // 隐藏快捷栏开着：栏不弹出（只拦显形，不拦 App 追踪，
        // 面板里的条子还要读运行中列表）
        guard !LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let keyWindow = self.keyWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            
            let screenBounds = keyWindow.bounds
            let currentDockWidth = self.dockWidth
            let initialHeight = Constants.initialDockShowHeight
            
            // If not already in view hierarchy, add it
            if hostingController.view.superview == nil {
                keyWindow.addSubview(hostingController.view)
                hostingController.view.frame = CGRect(
                    x: screenBounds.width - currentDockWidth,
                    y: (screenBounds.height - initialHeight) / 2,
                    width: currentDockWidth,
                    height: initialHeight
                )
            }
            
            self.updateDockFrame(animated: false) 
            
            self.setupEdgeGestureRecognizers()
            
            hostingController.view.alpha = 0
            let initialScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                let finalScale = Constants.initialScale
                hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
                // Move off-screen to hide, but keep in view hierarchy
                let screenBounds = self.keyWindow!.bounds
                let currentDockWidth = self.dockWidth
                let targetX = self.calculateTargetX(isDockHidden: true, isOnRightSide: hostingController.view.frame.midX > screenBounds.width / 2, dockWidth: currentDockWidth, screenWidth: screenBounds.width)
                let targetY = hostingController.view.frame.origin.y // Keep current Y
                hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
            } completion: { _ in
                self.isVisible = false
                hostingController.view.transform = .identity
            }
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)
        
        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isDockHidden else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }
    
    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        
        guard !self.isDockHidden, horizontalDistance > verticalDistance else {
            return false
        }
        
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        guard !self.isDockHidden else { return false }
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
        }
    }
    
    // 清掉无窗口的残留 dock 条目：容器已不在任何已装 App 名下，
    // 或对应 App 已不在（被删/被覆盖替换）。正在运行的窗口
    // （view 非空）一律不动；本函数不关任何窗口，只删条目记录。
    // 调用点：App 删除/覆盖安装/恢复完成，以及 bring-to-front 前
    // 的安全网。必须在主线程调（apps 是 @Published）。
    func pruneStaleDockEntries() {
        let allModels = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        var ownedContainers = Set<String>()
        for model in allModels {
            for container in model.uiContainers {
                ownedContainers.insert(container.folderName)
            }
            for container in model.appInfo.containers {
                ownedContainers.insert(container.folderName)
            }
        }
        let ownedBundlePaths = Set(allModels.compactMap { $0.appInfo.relativeBundlePath })
        apps.removeAll { entry in
            // 正在运行的窗口：view 是窗口存在的硬证据，一律不动。
            guard entry.view == nil else { return false }
            // 容器已无任何已装 App 认领 → 残留条目，剪掉。
            if !ownedContainers.contains(entry.appUUID) {
                return true
            }
            // 容器还在，但条目对应的 App 已不在（被覆盖替换后旧
            // 条目指着旧包路径）→ 剪掉；appInfo 缺失时无法证明
            // App 已走，留给带回守卫处理，不在这里剪。
            if let entryPath = entry.appInfo?.relativeBundlePath, !ownedBundlePaths.contains(entryPath) {
                return true
            }
            return false
        }
    }

    /// App 删除/覆盖安装/恢复完成 后调用：AppInfo 缓存与 dock
    /// 残留条目一起清掉，否则删掉/换掉的 App 还会按旧 LCAppInfo
    /// 被解析、旧 dock 条目还会被顶回前台。正在运行的窗口不动
    /// （见 pruneStaleDockEntries）。必须在主线程调。
    /// 注意：本类是 iOS 16+ 类，调用方须用 #available 包住。
    static func refreshAfterAppChanged() {
        AppInfoProvider.shared.clearCache()
        MultitaskDockManager.shared.pruneStaleDockEntries()
    }

    // C4 信号：最近一次 bring 调用是否清掉了死窗（见
    // bringMultitaskViewToFront；removeRunningApp 是异步的，
    // 调用方不能靠事后查 apps 来判断）。
    var czfLastBringCleanedDeadWindowUUID: String?

    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        // C4 信号：本次调用是否清掉了死窗——removeRunningApp
        // 是异步的，调用方不能靠事后查 apps 是否还在来判断，
        // 必须认这个同步置位的旗（每次调用入口先清零）。
        czfLastBringCleanedDeadWindowUUID = nil
        // 带回前先清残留条目：无窗口的过期条目若留着，find 会
        // 按 uuid 命中它（即使 view 为空也会走一圈）；清掉后带回
        // 失败即回 false，调用方自然走正常启动。正在运行的窗口
        // 不受影响（prune 从不剪 view 非空的条目）。
        pruneStaleDockEntries()
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                // C4：客进程已死的 stale 窗兜底——视图还在、pid 已无
                // （jetsam 后清理链丢了），带回只会顶回一帧死画面：
                // 拆条目 + 摘视图 + 清场景，返回 false 让调用方走
                // 正常启动（即重启入口）。进程活着一律不动；30 秒
                // 内的新窗不动（刚建窗时 pid 可能还没落位，误清
                // 正在启动的窗口比留一个死窗更糟）；条目对不上
                // （年龄未知）时保守不动。
                if let decoratedVC = targetView._viewDelegate() as? DecoratedAppSceneViewController,
                   let appSceneVC = decoratedVC.appSceneVC,
                   !appSceneVC.isAppRunning,
                   let entry = apps.first(where: { $0.appUUID == uuid }),
                   Date().timeIntervalSince(entry.czfAppearedAt) > 30 {
                    czfLastBringCleanedDeadWindowUUID = uuid
                    removeRunningApp(uuid)
                    targetView.removeFromSuperview()
                    appSceneVC.appTerminationCleanUp()
                    return false
                }
                passURLSchemeToView(targetView)
                // 用视图实际所在的窗口做置顶：findMultitaskView 不看 window 参数，
                // 循环第一个窗口未必是视图的窗口，窗口级置顶会抬错窗口。
                animateViewAppearance(targetView, from: center, in: targetView.window ?? window)
                return true
            }
        }
        
        return false
    }

    // 游客点按信号到达：按 bundleId 找到窗口，只调层级、不做脉冲动画。
    // 游客里每次点按都会发信号，带动画会点一下闪一下，故必须静默。
    @objc public func czfRaiseWindowForTouch(bundleId: String) {
        DispatchQueue.main.async {
            guard let app = self.apps.first(where: { $0.appInfo?.bundleIdentifier() == bundleId }),
                  let view = app.view,
                  let window = view.window ?? view.superview?.window else { return }
            self.bringViewToFront(view, in: window)
        }
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false

        // C2：带回前台时 PiP 未激活却残留 shouldIgnoreSceneUpdates
        // （WillStop 回调漏掉）→ 先清掉，否则此后场景更新全被丢、
        // 窗口只剩最后一帧；PiP 正激活时不动，stopPiP 也已同步清。
        if let decoratedVC, let appSceneVC = decoratedVC.appSceneVC,
           PiPManager.shared?.isPiP(withDecoratedVC: decoratedVC) != true,
           appSceneVC.shouldIgnoreSceneUpdates {
            appSceneVC.shouldIgnoreSceneUpdates = false
        }

        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            // 最小化省电恢复：藏着的窗口被叫回台前时清最小化标记、
            // 恢复前台。只走这条带取消隐藏的路，不走单纯调层级的
            // bringViewToFront（后者不取消隐藏，恢复了会藏着也变前台）。
            decoratedVC?.czfRestoreFromMinimize()
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            // C3：可见分支以前只走脉冲动画、不写前台——客经不藏
            // 视图路径被后台化后，窗口看着回了前台、客仍后台；
            // 这里补一次前台写（PiP 激活时 czfSetSceneForeground
            // 自己跳过，残留标志已由上面 C2 清掉）。单次慢点
            // 的脉冲动画本身不动。
            decoratedVC?.appSceneVC?.czfSetSceneForeground(true)

            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        DispatchQueue.main.async {
            self.apps.append(appModel)
            // C6：窗口出现信号（条目真正追加时才发，调用方凭
            // appUUID 过滤；串行门轮询的也是这个 apps 信号）。
            NotificationCenter.default.post(name: .czfMultitaskWindowAppeared, object: nil, userInfo: ["appUUID": appUUID])
            if let bid = appInfo?.bundleIdentifier() {
                self.czfRegisterTouchRaiseObserver(bundleId: bid)
            }

            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
            CZFHostKeepAlive.shared.refresh()
            self.czfEnforceRunningCap(newUUID: appUUID)
        }
    }

    /// C6 回调：等指定 dataUUID 的窗口出现（dock 条目追加）再
    /// 调 handler；超时（默认 30 秒）未出现则放弃等、不留野
    /// 观察者。调用方须在启动前注册——窗口出现先于注册的竞
    /// 态由开头的已存在检查兜底（已在就地调 handler）。
    func czfOnWindowAppeared(uuid: String, timeout: TimeInterval = 30, handler: @escaping () -> Void) {
        if apps.contains(where: { $0.appUUID == uuid }) {
            handler()
            return
        }
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: .czfMultitaskWindowAppeared, object: nil, queue: .main) { note in
            guard (note.userInfo?["appUUID"] as? String) == uuid else { return }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            handler()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    // 同时运行上限（CZF）：最多 3 个窗口。第 4 个窗口注册时
    // 才触发（App 页点开、快捷栏点开都走 addRunningAppWithInfo
    // 注册，所以两条路都拦得到；已在运行的点回来不算新注册）。
    // 候选只认已最小化的窗口：可见的不动、画中画豁免、没有
    // 最小化候选时不强制关可见窗口（上限此时是软上限，允许
    // 第 4 个留着）。弹确认，点了“关闭并继续”才关最久最小
    // 化的那个，点了“不开了”就关掉刚开的这个新窗口。
    private func czfEnforceRunningCap(newUUID: String) {
        guard apps.count > 3, !czfCapAlertShowing else { return }
        // 定时打开不弹框：定时执行时人可能不在手机前，弹框
        // 没人点就卡住；当天定时拉起的直接按软上限放行（第 4 个
        // 先留着，与无最小化候选时一致），不关可见窗口。
        if czfIsSchedMinOpened(uuid: newUUID) { return }
        let candidates = apps.filter { app in
            guard app.appUUID != newUUID,
                  let view = app.view,
                  view.isHidden,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
                  PiPManager.shared?.isPiP(withDecoratedVC: vc) != true else {
                return false
            }
            return true
        }
        guard let oldest = candidates.sorted(by: {
            // 没计时条目的窗口是 60 秒轮询还没扫到的新最小化，
            // 按现在算（最新），不能按 distantPast 算最久，否则
            // 刚最小化的反而会被先关掉。
            (czfMinimizedSince[$0.appUUID] ?? Date()) < (czfMinimizedSince[$1.appUUID] ?? Date())
        }).first else { return }
        guard let keyWindow = self.keyWindow else { return }
        var top = keyWindow.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        guard let presenter = top else { return }
        czfCapAlertShowing = true
        let alert = UIAlertController(
            title: "同时运行已满 3 个",
            message: "关闭最久最小化的「\(oldest.appName)」并继续打开新 App？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "关闭并继续", style: .default) { [weak self] _ in
            self?.czfCapAlertShowing = false
            self?.closeAppWindow(uuid: oldest.appUUID)
        })
        alert.addAction(UIAlertAction(title: "不开了，关新 App", style: .destructive) { [weak self] _ in
            self?.czfCapAlertShowing = false
            self?.closeAppWindow(uuid: newUUID)
        })
        presenter.present(alert, animated: true)
    }

    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    @objc public func minimizeWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                app.view?.layer.removeAllAnimations()
                vc.minimizeWindow()
            }
        }
    }

    // 关闭单个运行中 App（面板顶部状态栏的图标右上角 ✕ 用）
    @objc public func closeAppWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                vc.closeWindow()
            }
        }
    }

    // 一键重启运行中的 App（卡死时用）：关掉窗口，等它退
    // 干净再按平时的启动路线重新拉起
    @objc public func restartApp(uuid: String) {
        guard let app = self.apps.first(where: { $0.appUUID == uuid }) else { return }
        let bundlePath = app.appInfo?.relativeBundlePath ?? ""
        closeAppWindow(uuid: uuid)
        guard !bundlePath.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // 跳错修复：重启不再走只带包名的 URL（那边按包名
            // 取首个模型，重启第 2 个实例会拉起第 1 个）；但
            // restartApp 手里只有 DockAppModel（无 runApp），
            // 直启走不通，改走 URL 但补 container-folder-name
            //（launchAppWithBundleId 已支持，直达被关实例的容器）。
            // bundlePath 是 .app 文件夹名，可能含空格；直接拼 URL(string:)
            // 会返回 nil，重启就变成只关不开。先 percent-encoding 再拼。
            let encodedBundlePath = bundlePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundlePath
            if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)&container-folder-name=\(uuid)") {
                #if !os(visionOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #endif
            }
        }
    }

    // MARK: - 定时最小化打开（CZF）
    // 每个 App 在其设置页单独开关+定时间（UserDefaults 键 CZFSchedMin*，
    // 按 bundleIdentifier 存）。宿主活着时每 30 秒查一轮：到点且今天
    // 还没开过 → 拉起并最小化，一轮最多开一个（避免同时拉起多个）。
    // 宿主被彻底关掉时 iOS 不会唤醒它，到点没开成的会在下次打开
    // LiveContainer 时由同一轮检查补开。
    private func startScheduledMinimizeOpenTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.czfSchedMinTimer?.invalidate()
            self.czfSchedMinTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.checkScheduledMinimizeOpen()
            }
            self.checkScheduledMinimizeOpen()
        }
    }

    /// 供设置页定时开关写盘时调用（见 LCAppSettingsView
    /// .saveSchedMinSettings）：确保定时器在跑，重复调无害；
    /// 关掉唯一一个定时后，下一轮检查发现无定时会自己停表。
    @objc public func czfKickSchedMinTimer() {
        startScheduledMinimizeOpenTimer()
    }

    // 定时器不再常驻：check 里没有任何 App 开着定时就停表，
    // 下次开定时时由设置页 kick 重起；已开但今天已开过的
    // 不算“没有”，明天还得靠它触发，所以只认开关，不认
    // 今日已开标记。日期格式器只建一次，不再每 30 秒新建。
    private static let schedMinDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private func checkScheduledMinimizeOpen() {
        let defaults = UserDefaults.standard
        let today = Self.schedMinDayFormatter.string(from: Date())
        let cal = Calendar.current
        let now = Date()
        let nowTotal = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        var hasEnabled = false
        for app in allApps {
            guard let bundleId = app.appInfo.bundleIdentifier() else { continue }
            guard defaults.bool(forKey: "CZFSchedMinEnabled-\(bundleId)") else { continue }
            hasEnabled = true
            if defaults.string(forKey: "CZFSchedMinLastDate-\(bundleId)") == today { continue }
            let target = defaults.integer(forKey: "CZFSchedMinMinutes-\(bundleId)")
            if nowTotal < target { continue }
            guard app.appInfo.dataUUID != nil,
                  app.appInfo.relativeBundlePath != nil else { continue }
            // 先记账再打开，防同一天重复触发
            defaults.set(today, forKey: "CZFSchedMinLastDate-\(bundleId)")
            czfMinimizeOpenApp(app: app)
            break
        }
        // 一个定时都没开：停掉定时器，不再每 30 秒空扫；
        // 下次开定时时由设置页 kick 重起。
        if !hasEnabled {
            czfSchedMinTimer?.invalidate()
            czfSchedMinTimer = nil
        }
    }

    /// 定时打开当天标记：拉起前就记，注册时上限检查、
    /// 最小化后自动关检查都认这张名单。
    private func czfMarkSchedMinOpened(uuid: String) {
        let today = Self.schedMinDayFormatter.string(from: Date())
        if czfSchedMinOpenedDay != today {
            czfSchedMinOpenedDay = today
            czfSchedMinOpenedUUIDs.removeAll()
        }
        czfSchedMinOpenedUUIDs.insert(uuid)
    }

    private func czfIsSchedMinOpened(uuid: String) -> Bool {
        let today = Self.schedMinDayFormatter.string(from: Date())
        if czfSchedMinOpenedDay != today {
            czfSchedMinOpenedDay = today
            czfSchedMinOpenedUUIDs.removeAll()
            return false
        }
        return czfSchedMinOpenedUUIDs.contains(uuid)
    }

    // 与快捷栏面板的「最小化打开」同一套路：已在运行直接最小化窗口；
    // 未运行先直启该实例，再轮询等窗口出现后最小化。
    private func czfMinimizeOpenApp(app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        czfMarkSchedMinOpened(uuid: dataUUID)
        if apps.contains(where: { $0.appUUID == dataUUID }) {
            minimizeWindow(uuid: dataUUID)
            return
        }
        // 跳错修复：不再走只带包名的 URL（按包名取首个模型，
        // 定时打开多开实例会拉起首个实例），改走模型直启。
        Task {
            try? await app.runApp(containerFolderName: dataUUID)
        }
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            attempts += 1
            guard let self else {
                timer.invalidate()
                return
            }
            if self.apps.contains(where: { $0.appUUID == dataUUID }) {
                self.minimizeWindow(uuid: dataUUID)
                timer.invalidate()
            } else if attempts >= 120 {
                timer.invalidate()
            }
        }
    }

    // MARK: - 最小化自动关（CZF）
    // 开关在多任务设置页，键 CZFMinAutoCloseEnabled，键不存在 = 开；
    // 时长键 CZFMinAutoCloseMinutes，10 / 30 / 60 分钟，默认 30。
    // 只关“已最小化满设定时长”的窗口：可见的、画中画的、已关的都不动；
    // 恢复可见后计时清零，重最小化重新计时间。60 秒一轮，误差
    // 不超过一轮；宿主被彻底关掉时定时器不跑，不存在补关误伤。
    // 定时器不再常驻：checkMinAutoClose 发现没有最小化窗口
    // 计时（或开关已关）就停掉；窗口最小化时由 czfKickMinAutoCloseTimer
    // 重新起——最小化必经 DecoratedAppSceneViewController.minimizeWindow
    //（标题栏按钮、快捷栏最小化全部、Swift 侧 minimizeWindow 都走它），
    // 该方法完成隐藏后调这个 kick，start 本身幂等、重复调只会
    // 重建同一个定时器，不会叠加。
    private func startMinAutoCloseTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.czfMinAutoCloseTimer?.invalidate()
            self.czfMinAutoCloseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.checkMinAutoClose()
            }
            self.checkMinAutoClose()
        }
    }

    /// 供 ObjC 侧最小化完成时调用（见 DecoratedAppSceneViewController
    /// .minimizeWindow）：确保自动关定时器在跑，重复调无害。
    @objc public func czfKickMinAutoCloseTimer() {
        startMinAutoCloseTimer()
    }

    private func checkMinAutoClose() {
        let defaults = LCUtils.appGroupUserDefault
        let enabled = defaults.object(forKey: "CZFMinAutoCloseEnabled") == nil || defaults.bool(forKey: "CZFMinAutoCloseEnabled")
        guard enabled else {
            czfMinimizedSince.removeAll()
            czfMinAutoCloseTimer?.invalidate()
            czfMinAutoCloseTimer = nil
            return
        }
        // 自动关时长（CZF，可调）：设置页“最小化省电”里选
        // 10 / 30 / 60 分钟或“不关闭”，默认 30 分钟（以前写死
        // 1800 秒）。键不存在时默认 30；显式选 0（不关闭）时
        // 不自动关——跟关掉上面开关一个效果（3.8.282）。
        // 注意：不能用 integer(forKey:) 的 0 兜底（键不存在也
        // 返回 0，会把“从没选过”误读成“不关闭”），先判 object。
        let closeMinutes = defaults.object(forKey: "CZFMinAutoCloseMinutes") as? Int ?? 30
        if closeMinutes == 0 {
            czfMinimizedSince.removeAll()
            czfMinAutoCloseTimer?.invalidate()
            czfMinAutoCloseTimer = nil
            return
        }
        let closeDelay = TimeInterval([10, 30, 60].contains(closeMinutes) ? closeMinutes : 30) * 60
        let now = Date()
        var toClose: [String] = []
        for app in apps {
            guard let view = app.view,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController else {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 画中画在播视频：豁免，不计也不关。
            if PiPManager.shared?.isPiP(withDecoratedVC: vc) == true {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 保活白名单：豁免，不计也不关。以前白名单只管宿主
            // 音频保不保，自动关照样关，同一个“保活”两个意思
            // 打架；现在名单里的最小化窗口自动关直接跳过。
            // 文件不存在时 isInKeepAliveWhitelist 返回 false，
            // 自动关照常跑，不会把默认自动关废掉。
            if let bid = app.appInfo?.bundleIdentifier(), !bid.isEmpty,
               CZFHostKeepAlive.isInKeepAliveWhitelist(for: bid) {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 定时打开当天：豁免，不计也不关。定时拉起就是要
            // 它在后台待命，最小化满 30 分钟就关等于白开；
            // 只豁免当天，次日恢复正常（见 czfIsSchedMinOpened）。
            if czfIsSchedMinOpened(uuid: app.appUUID) {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
                continue
            }
            // 只认真正藏起来的：动画中途 alpha 为 0 但 hidden 还没置位
            // 时不算，避免 0.2 秒动画就开始计时。
            if view.isHidden {
                if let since = czfMinimizedSince[app.appUUID] {
                    if now.timeIntervalSince(since) >= closeDelay {
                        toClose.append(app.appUUID)
                    }
                } else {
                    czfMinimizedSince[app.appUUID] = now
                }
            } else {
                czfMinimizedSince.removeValue(forKey: app.appUUID)
            }
        }
        // 已不在运行列表里的计时一并清掉，防 uuid 复用后误关新窗。
        let liveUUIDs = Set(apps.map { $0.appUUID })
        czfMinimizedSince = czfMinimizedSince.filter { liveUUIDs.contains($0.key) }
        for uuid in toClose {
            czfMinimizedSince.removeValue(forKey: uuid)
            closeAppWindow(uuid: uuid)
        }
        // 没有最小化窗口在计时了：停掉定时器，不再每 60 秒
        // 空扫 apps；下次窗口最小化时由 kick 重新起。
        if czfMinimizedSince.isEmpty {
            czfMinAutoCloseTimer?.invalidate()
            czfMinAutoCloseTimer = nil
        }
    }

    // 最大化指定 App（状态栏点按用）：vc 的 maximizeWindow() 是
    // 切换式的（已最大化时调它反而还原小窗口），只在没最大化
    // 时调一次。
    @objc public func maximizeWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               !vc.isMaximized {
                vc.maximizeWindow()
            }
        }
    }

    // 收起专用：台前 App 未最大化就最大化，已最大化或没前台
    // App 时空操作；与折叠栏、关面板一起达成图一全屏效果。
    @objc public func maximizeFrontmostWindow() {
        guard let front = czfFrontmostApp() else { return }
        maximizeWindow(uuid: front.appUUID)
    }

    // 小窗口打开指定 App（状态栏长按用，用户定：长按是小窗口
    // 不是最小化）：同样借切换式的 maximizeWindow()——已最大化
    // 时调一次正好还原成小窗口；本来就是小窗口的不动。
    @objc public func restoreSmallWindow(uuid: String) {
        DispatchQueue.main.async {
            if let app = self.apps.first(where: { $0.appUUID == uuid }),
               let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
               vc.isMaximized {
                vc.maximizeWindow()
            }
        }
    }
    
    @objc public func closeAllWindows() {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    vc.closeWindow()
                }
            }
        }
    }
    
    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.updateDockFrame()
            self.notifyDockCollapseChanged()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func showDockFromHidden() {
        // 隐藏快捷栏开着：右缘划出也不唤回栏（左缘开面板不受影响）
        guard !LCUtils.appGroupUserDefault.bool(forKey: "LCHideDock") else { return }
        DispatchQueue.main.async {
            self.isDockHidden = false
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.isDockHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    // MARK: - 边缘拖动手势（边缘起手横拖 隐藏/显示 快捷栏）
    // 只认从屏幕边缘一条（44pt）起手的横拖：栏在右时，边缘往右拖隐藏、
    // 往左拖显示；其他区域完全不碰，不干扰 App 内容。
    // 注意：游客 App 的内容是独立场景窗口，触摸不经过宿主窗口，
    // 所以必须给每个场景的每个窗口都挂上，宿主窗口一个不够。
    private var globalSwipeRecognizers: [UIPanGestureRecognizer] = []
    // 全窗口手势的起手位置：0=不在边缘 1=左边缘 2=右边缘
    private var globalSwipeStartEdge: Int = 0
    // 起手 x：终结位移跟起手位置挂钩用（与客侧 gCZFStartX 同款，
    // 用户 2026-11-04 令，2 号机制修）
    private var globalSwipeStartX: CGFloat = 0
    // 边缘手势启用带：边缘起手的触摸只有落在屏幕高度的一段
    // 内才算数，上下不调（防误触）。2026-10-24 用户红圈定：
    // 调用带移到屏幕底部 10%–30% 一段（从顶算 70%–90%，
    // 别再放中间）；三档同中心 80%，低=带更窄、高=带更宽。
    // TweakLoader 内手势用中档值，宿主这边按档位做
    // 最终判定，两边中档必须同值。
    private static var czfEdgeBandTop: CGFloat { czfEdgeBandValues.top }
    private static var czfEdgeBandBottom: CGFloat { czfEdgeBandValues.bottom }
    private static var czfEdgeBandValues: (top: CGFloat, bottom: CGFloat) {
        switch czfEdgeSensitivity {
        case 0: return (0.75, 0.85)
        case 2: return (0.65, 0.95)
        default: return (0.70, 0.90)
        }
    }
    // 灵敏度档位：0 低 1 中（默认）2 高（设置页可调）
    private static var czfEdgeSensitivity: Int {
        UserDefaults.standard.object(forKey: "CZFEdgeSensitivity") as? Int ?? 1
    }
    // 往外弹启用带：用户 2026-11-04 令左往左滑根本不好用、检查
    // 好修复——11-03 把往外弹带收窄到跟 App 面板一致（0.70–0.90）
    // 后，左滑大半高度都认不出；恢复收窄前的好用值（中档
    // 0.55–0.93，低 0.65–0.90、高 0.50–0.95），左滑带宽回
    // 来才灵敏。App 面板往里拖仍用普通带，不动。
    private static var czfEdgeOutwardBandValues: (top: CGFloat, bottom: CGFloat) {
        switch czfEdgeSensitivity {
        case 0: return (0.65, 0.90)
        case 2: return (0.50, 0.95)
        default: return (0.55, 0.93)
        }
    }
    private static var czfEdgeOutwardBandTop: CGFloat { czfEdgeOutwardBandValues.top }
    private static var czfEdgeOutwardBandBottom: CGFloat { czfEdgeOutwardBandValues.bottom }
    // 触发距离系数：低档要拖得更远才认、高档拖一点就认
    private static var czfThresholdScale: CGFloat {
        switch czfEdgeSensitivity {
        case 0: return 1.4
        case 2: return 0.6
        default: return 1.0
        }
    }
    // 边缘手势总开关（设置页控制，键不存在 = 开）
    static var czfEdgeGesturesEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "CZFEdgeGesturesEnabled") == nil || d.bool(forKey: "CZFEdgeGesturesEnabled")
    }
    private var globalSwipeStartInBand: Bool = true
    // 起手是否落在往外弹专用带内（比普通带宽，只给往外弹用；
    // 往里拖与右边缘一律不认它，见下方两个判定函数）。
    private var globalSwipeStartInOutwardBand: Bool = true
    private var globalSwipeObserversInstalled = false
    // 边缘手势一次性闩锁：一次拖动只触发一次动作（源面板入口带震动，
    // 不闩住会在 .changed 里连震好几下）
    private var czfEdgeSwipeLatched = false
    // 左边缘系统手势（2026-11-04 22:xx）：直接左滑被系统在落指时
    // 就认领、App 侧触摸没动就死了，sendEvent 再松的阈值也接不住
    // （272 改阈值零变化实证）。UIScreenEdgePanGestureRecognizer 是
    // 系统认可的边缘手势，系统不会抢先认领它的触摸，专接左滑一路；
    // 往里仍走原来好用的 pan，sendEvent 钩子留作 x 21–44 起手的后备。
    private var czfLeftEdgePanRecognizers: [UIScreenEdgePanGestureRecognizer] = []
    private var czfLeftEdgePanFired: Set<ObjectIdentifier> = []

    @objc private func handleGlobalLeftEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        switch gesture.state {
        case .ended, .cancelled, .failed:
            czfLeftEdgePanFired.remove(ObjectIdentifier(gesture))
            return
        case .began, .changed:
            break
        default:
            return
        }
        let id = ObjectIdentifier(gesture)
        guard !czfLeftEdgePanFired.contains(id) else { return }
        let t = gesture.translation(in: gesture.view)
        let s = Self.czfThresholdScale
        // 只接往外（左移）；往里（右移）不碰，走原来好用的 pan。
        // 优化 1 号：实时比 0.9→0.4，斜滑中途就触发；
        // 优化 3 号：补 flick 路（与客侧 CZFIsOutwardFlick 同参：
        // 位移 −2 + 左向速度 ≤−300），短促快甩也接住。
        let v = gesture.velocity(in: gesture.view)
        if (t.x <= -6 * s && abs(t.x) > 0.4 * abs(t.y)) || (t.x <= -2 && v.x <= -300) {
            czfLeftEdgePanFired.insert(id)
            // 3.8.284：认领了源面板，客 App 的触摸到此为止
            if let window = gesture.view as? UIWindow {
                Self.czfCancelGuestTouches(in: window)
            }
            self.czfOpenSourcesPanelFromFunnel()
        }
    }

    private func setupGlobalSwipeRecognizer() {
        // 宿主 sendEvent 直读只装一次（左滑出源面板专用，见下）。
        _ = Self.czfHostSendEventInstalled
        // 游客 App 的窗口出现得晚：监听新窗口/新场景，一出现就补装
        if !globalSwipeObserversInstalled {
            globalSwipeObserversInstalled = true
            NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setupGlobalSwipeRecognizer()
            }
            NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setupGlobalSwipeRecognizer()
            }
        }
        globalSwipeRecognizers.removeAll { $0.view == nil }
        czfLeftEdgePanRecognizers.removeAll { $0.view == nil }
        var windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        // 兜底：全进程窗口（含非 UIWindowScene 托管的游客窗口）
        for window in UIApplication.shared.windows where !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }
        for window in windows {
            if globalSwipeRecognizers.contains(where: { $0.view === window }) {
                continue
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGlobalSwipe(_:)))
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            globalSwipeRecognizers.append(pan)
            if !czfLeftEdgePanRecognizers.contains(where: { $0.view === window }) {
                let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleGlobalLeftEdgeSwipe(_:)))
                edgePan.edges = .left
                edgePan.cancelsTouchesInView = false
                edgePan.delegate = self
                window.addGestureRecognizer(edgePan)
                czfLeftEdgePanRecognizers.append(edgePan)
            }
        }
    }

    // MARK: - 宿主 sendEvent 直读（左滑出源面板专用，2026-11-04）
    // 宿主窗口 pan 在代码上全对、但真机左滑（往外弹）仍不可靠：
    // 手指几毫米就出屏，识别器那步可能直接丢触摸。客侧漏斗
    // 用 sendEvent 直读原始触摸才灵敏，宿主照抄同款机制：
    // 只接左滑（往外弹）一路，右滑（往里拖）仍走原来好用的
    // pan，一律不动；pan 的往外弹分支同步停用，避免两路重复。
    // 钩子名用 czf_host_ 前缀，与客侧 czf_ 区分开，万一同进程
    // 也不撞；只观察、绝不拦截/改事件，原实现先转发。
    // 注意：extension 里的钩子方法必须加 dynamic，否则 Swift
    // 静态分发会自递归（交换后调自己、栈溢出），切勿去掉。
    private static let czfHostSendEventInstalled: Void = {
        guard let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let swizzled = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.czf_host_sendEvent(_:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }()
    private static var czfHostOutwardTouches = [UITouch: CGPoint]()

    // 3.8.284：面板手势认领后取消客 App 的触摸（用户真机报“滑
    // 动面板时 App 内也动了”）：宿主原来只观察不拦截（sendEvent
    // 钩子纯观察、窗口手势 cancelsTouchesInView = false、代理还
    // 允许同时识别），面板手势和 App 自己的横滑两边同动。认领
    // 的一刻把触摸所在窗口的交互关一下——UIKit 会立刻给正在
    // 跟踪的视图/识别器发 touchesCancelled，客 App 的横滑就停
    // 住弹回；下一轮 runloop 再打开，不影响之后的操作。只在认
    // 领时关（下面三处），没认领的触摸一律不动，客 App 自己的
    // 返回/滑动不受影响；终结兜底（.ended/.cancelled 才触发的）
    // 触摸已经结束，没什么可取消，不关。
    private static func czfCancelGuestTouches(in window: UIWindow) {
        window.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            window.isUserInteractionEnabled = true
        }
    }

    static func czfHostOutwardObserve(window: UIWindow, event: UIEvent) {
        guard let touches = event.allTouches, !touches.isEmpty else { return }
        let height = window.bounds.height
        guard height > 0 else { return }
        let top = Self.czfEdgeOutwardBandTop
        let bottom = Self.czfEdgeOutwardBandBottom
        let s = Self.czfThresholdScale
        for touch in touches {
            let loc = touch.location(in: window)
            switch touch.phase {
            case .began:
                // 用户 2026-11-04 23:16 令改成 65pt（80pt 仍嫌宽）：
                // 起手横向区收窄到 65pt（只动左滑一路，带/阈值/右滑一律不动）。
                if loc.x <= 65, loc.y >= height * top, loc.y <= height * bottom {
                    czfHostOutwardTouches[touch] = loc
                }
            case .moved:
                guard let start = czfHostOutwardTouches[touch] else { continue }
                let dx = loc.x - start.x
                let dy = loc.y - start.y
                if dx <= -6 * s, abs(dx) > 0.4 * abs(dy) {
                    czfHostOutwardTouches.removeValue(forKey: touch)
                    // 3.8.284：认领了源面板，客 App 的触摸到此为止
                    Self.czfCancelGuestTouches(in: window)
                    Self.shared.czfOpenSourcesPanelFromFunnel()
                }
            case .ended:
                if let start = czfHostOutwardTouches[touch] {
                    let dx = loc.x - start.x
                    let dy = loc.y - start.y
                    // 终结与客侧 CZFIsOutwardEnded 同参（贴边 3、离边 6、比 0.2）：
                    // 271 原值离边 8*s、比 0.4 过严，慢速弧线接不住。
                    let need: CGFloat = start.x <= 20 ? 3 : 6
                    if dx <= -need, abs(dx) > 0.2 * abs(dy) {
                        Self.shared.czfOpenSourcesPanelFromFunnel()
                    }
                    czfHostOutwardTouches.removeValue(forKey: touch)
                }
            case .cancelled:
                if let start = czfHostOutwardTouches[touch] {
                    let dx = loc.x - start.x
                    let dy = loc.y - start.y
                    // 取消即往外意图，与客侧 CZFIsOutwardCancelled 同参
                    // （净左移 ≥2pt、比 0.2）：一次性左滑常被系统/ App
                    // 仲裁早取消，取消时位移已无从再长，271 原值
                    // （3/8*s、比 0.4）够不着才不出；右滑按住再左能出，
                    // 正因触摸没被早取消、moved 路有机会触发。
                    if dx <= -2, abs(dx) > 0.2 * abs(dy) {
                        Self.shared.czfOpenSourcesPanelFromFunnel()
                    }
                    czfHostOutwardTouches.removeValue(forKey: touch)
                }
            default:
                break
            }
        }
    }

    @objc private func handleGlobalSwipe(_ gesture: UIPanGestureRecognizer) {
        // 不再要求 isVisible：源面板和 App 面板都要在"没打开任何
        // App"时也能从主界面调出（用户定：任意位置可调出面板）。
        // 其余动作入口（显隐快捷栏/全屏切换）自带场景守卫，在主
        // 界面裸跑时各自落空，不会误触发。
        //
        // 判定模型与 TweakLoader 内手势对齐：滑动中过门槛即
        // 触发（不等抬指），终结/被取消时再走一遍宽松兜底（只看物理
        // 结果：净位移方向 + 落点贴边，方向比只留底线）。原来只在
        // .ended 拿全程位移卡 1.5 倍方向比——手指在屏幕上/下部天然
        // 走弧线、纵向位移大，整段被判掉，真机表现就是"只有中间
        // 一段灵、上下无效"，且被列表滚动取消（.cancelled）时直接
        // 不判；插件侧有 sendEvent 漏斗直读原始触摸才显得灵敏。
        let translation = gesture.translation(in: gesture.view)
        let endX = gesture.location(in: gesture.view).x
        let width = gesture.view?.bounds.width ?? 0
        switch gesture.state {
        case .began:
            czfEdgeSwipeLatched = false
        case .changed:
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand || globalSwipeStartInOutwardBand, !czfEdgeSwipeLatched else { return }
            if processGlobalSwipe(startEdge: globalSwipeStartEdge, startInBand: globalSwipeStartInBand, startInOutwardBand: globalSwipeStartInOutwardBand, translation: translation, endX: endX, width: width) {
                czfEdgeSwipeLatched = true
                // 3.8.284：认领了面板手势（开 App 面板/切 App/
                // 藏栏），客 App 的触摸到此为止
                if let window = gesture.view as? UIWindow {
                    Self.czfCancelGuestTouches(in: window)
                }
            }
        case .ended, .cancelled:
            defer { czfEdgeSwipeLatched = false }
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand || globalSwipeStartInOutwardBand, !czfEdgeSwipeLatched else { return }
            processGlobalSwipeFallback(startEdge: globalSwipeStartEdge, startInBand: globalSwipeStartInBand, startInOutwardBand: globalSwipeStartInOutwardBand, translation: translation, endX: endX, width: width, startX: globalSwipeStartX)
        default:
            break
        }
    }

    // 终结兜底判定：与 TweakLoader 内手势触摸漏斗的终结规则同参。
    // 只认边缘起手；任意位置起手不兜底（防误触设计不变）。
    private func processGlobalSwipeFallback(startEdge: Int, startInBand: Bool, startInOutwardBand: Bool, translation: CGPoint, endX: CGFloat, width: CGFloat, startX: CGFloat) {
        let dx = translation.x
        let dy = translation.y
        let s = Self.czfThresholdScale
        if startEdge == 1 {
            // 2026-10-23 真机纠正后对调：左边缘往里拖（手指右移）
            // = App 面板，往外弹（手指左移）= 源面板。门槛跟着动作
            // 的物理方向走，不跟面板走（往里拖与 App 内横滑同轨，
            // 门槛保持严；往外弹空间小，门槛保持松）
            // 往外弹带已恢复 0.55–0.93（2026-11-04 左滑修复），
            // 往里拖仍只认普通带。
            // 2026-11-04 2 号机制修：位移门槛跟起手位置挂钩——
            // 贴边起手（≤20pt，与客侧 kCZFEdgeTouchMax 同值）
            // 只认 3pt，离边维持 8×s（灵敏度档照旧）。
            // 256修：往外弹不再验落点贴边（同客侧理由）。
            // 2026-11-04 sendEvent 直读接管往外弹后，兜底不再
            // 触发源面板，避免两路重复；往里拖（App 面板）不变。
            if dx >= 44 * s, abs(dx) > 0.8 * abs(dy), startInBand {
                fireDockAction { self.czfOpenAppPanel() }
            }
        } else if startEdge == 2 {
            // 右边缘不放宽：两个方向都只认普通带。
            if dx >= 8 * s, endX >= width - 12, abs(dx) > 0.4 * abs(dy), startInBand {
                fireDockAction { self.czfEdgeRightOutward() }
            } else if dx <= -44 * s, abs(dx) > 0.8 * abs(dy), startInBand {
                fireDockAction { self.czfEdgeRightInward() }
            }
        }
    }

    // 手势判定核心：宿主窗口手势与悬浮边条窗共用。
    // startEdge：0=任意位置 1=左边缘 2=右边缘；往外滑门槛低（手指很快滑出屏幕）。
    // startInBand：起手是否落在启用带内；任意位置起手拖到右边缘切 App 也要带内
    // 才触发（2026-11-01 用户定：右边跟左边一样，只认带内）。
    // 返回 true 表示本次判定触发了动作（边条 handler 据此做一次性触发）
    @discardableResult
    private func processGlobalSwipe(startEdge: Int, startInBand: Bool, startInOutwardBand: Bool, translation: CGPoint, endX: CGFloat, width: CGFloat) -> Bool {
        let draggingRight = translation.x > 0
        // 往外弹（左缘左移/右缘右移）物理行程就只有起手那几十
        // 点：手指几毫米就出屏，拇指走的还是弧线、纵向分量大，
        // 方向比按 1.5 卡会把大半次弹滑判掉（用户真机反馈左缘
        // 往左弹很不灵敏）。往外方向方向比放宽到 0.9、距离门槛
        // 降到 6：贴边往外滑没有任何 App 手势同轨，放宽不抢
        // 东西；往里拖和任意位置维持原判定不变
        let isOutward = (startEdge == 1 && !draggingRight) || (startEdge == 2 && draggingRight)
        guard abs(translation.x) > (isOutward ? 0.9 : 1.5) * abs(translation.y) else { return false }
        let s = Self.czfThresholdScale
        if startEdge == 2 {
            // 右边缘不放宽：两个方向都只认普通带（调用点门槛
            // 放宽后，往外弹带起手的右边缘滑动到这里照样不触发）。
            guard startInBand else { return false }
            // 右边缘改派：往左/往右的动作在入口判定（切换已打开
            // App：往左上一个、往右下一个）；门槛乘灵敏度系数（设置页三档）
            if draggingRight {
                guard translation.x > 6 * s else { return false }
                fireDockAction { self.czfEdgeRightOutward() }
            } else {
                guard abs(translation.x) > 24 * s else { return false }
                fireDockAction { self.czfEdgeRightInward() }
            }
            return true
        } else if startEdge == 1 {
            // 左边缘（2026-10-23 真机纠正后对调）：往里拖（手指
            // 右移，门槛30）= App 面板；往外弹（手指左移，门槛10）
            // = 源面板。与插件侧判定保持一致；门槛跟着物理方向
            // 走：往里拖与 App 内横滑同轨，30 的门槛只认边缘起手
            // 的决断横拖，不抢 App 自己的滑动。
            // 往外弹带已恢复 0.55–0.93（2026-11-04 左滑修复），
            // 往里拖仍只认普通带——带外起手的往里拖到这里返回
            // false 不闩锁，之后改往外弹仍能触发。
            if draggingRight {
                guard startInBand else { return false }
                guard translation.x > 30 * s else { return false }
                fireDockAction { self.czfOpenAppPanel() }
            } else {
                // 往外弹已由宿主 sendEvent 直读接管（2026-11-04），
                // pan 不再触发源面板，避免两路重复；返回 false
                // 不闩锁，之后改往里拖仍能触发。
                return false
            }
            return true
        } else {
            // 任意位置起手：拖到屏幕边缘、位移 >50 才算隐藏；
            // 拖到右边缘切 App 也要起手在带内（跟左边一样），
            // 带外起手往右拖到边不切；往左拖到边藏栏维持原样
            guard abs(translation.x) > 50 else { return false }
            if draggingRight && startInBand && endX >= width - 30 {
                fireDockAction { self.czfEdgeRightOutward() }
                return true
            } else if !draggingRight && endX <= 30 {
                fireDockAction { self.czfEdgeLeftOutward() }
                return true
            }
            return false
        }
    }

    // 手势动作统一入口：只执行，不在这里震——震动由各动作在真正
    // 生效的点自己给一次（原来这里一下+入口一下+插件一下，一滑
    // 震两三下，用户反馈像滑了两次）。
    private func fireDockAction(_ action: () -> Void) {
        action()
    }

    // 起手点落在控件/滑块类视图上时，全局手势不接：视频
    // 进度条一般在底部横跨全屏，从边缘 44pt 附近起手横拖
    // 本来正落在边缘区 + 启用带双命中区，位移一过门槛就
    // 触发面板/切 App，还跟 App 手势同时识别两边同动。
    // 顺着触摸视图往上查祖先：UIControl（UISlider、按钮等）
    // 全算，类名含 slider/scrub/seek/progress 的自定义
    // 进度条（非 UIControl、自带 pan 的那种）也算；只拦
    // 全局 pan 这一路，不动面板自身的边缘识别器。
    private func czfTouchOnControlOrSlider(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UIControl { return true }
            let name = String(describing: type(of: v)).lowercased()
            if name.contains("slider") || name.contains("scrub") || name.contains("seek") || name.contains("progress") {
                return true
            }
            view = v.superview
        }
        return false
    }

    // 只认滑块/进度条类（拖动会跟 pan 冲突的那种），普通按钮
    // 不算——边缘按钮上的滑动要放行给全局手势。
    private func czfTouchOnSliderOrProgress(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let v = view {
            if v is UISlider { return true }
            let name = String(describing: type(of: v)).lowercased()
            if name.contains("slider") || name.contains("scrub") || name.contains("seek") || name.contains("progress") {
                return true
            }
            view = v.superview
        }
        return false
    }

    // 全部接收、只记录起手位置；触发判定在 handler 里按起手+落点做
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 屏幕边缘识别器：栏隐藏那支按普通带放行；左滑出源面板
        // 那支（czfLeftEdgePanRecognizers）按往外弹带放行（比普通带宽），
        // 带外的触摸直接不让它识别。
        if gestureRecognizer is UIScreenEdgePanGestureRecognizer,
           let window = gestureRecognizer.view as? UIWindow {
            let y = touch.location(in: window).y
            let height = window.bounds.height
            if czfLeftEdgePanRecognizers.contains(where: { $0 === gestureRecognizer }) {
                return y >= height * Self.czfEdgeOutwardBandTop && y <= height * Self.czfEdgeOutwardBandBottom
            }
            return y >= height * Self.czfEdgeBandTop && y <= height * Self.czfEdgeBandBottom
        }
        guard globalSwipeRecognizers.contains(where: { $0 === gestureRecognizer }),
              let window = gestureRecognizer.view as? UIWindow else { return true }
        // 用户 2026-11-04 令：左往左滑根本不好用——折叠滑块
        // 也不拦：收起后栏收成滑块贴在左缘，拦滑块就等于左
        // 缘手势全死（左滑出源面板失灵的根因之一）；栏上滑
        // 动一律进全局手势。
        // 边缘起手且落在普通控件（App 行按钮、导航按钮等）上时
        // 不拦：点按无位移不会触发 pan，不影响点按；滑动则进
        // 全局手势——否则左缘被按钮盖住时左滑全死（根本不好
        // 用的另一根因）。滑块/进度条仍拦（拖动会跟 pan 同时动）。
        if czfTouchOnControlOrSlider(touch) {
            let edgeLoc = touch.location(in: window)
            let atEdge = edgeLoc.x <= 44 || edgeLoc.x >= window.bounds.width - 44
            if !(atEdge && !czfTouchOnSliderOrProgress(touch)) {
                globalSwipeStartEdge = 0
                return false
            }
        }
        let loc = touch.location(in: window)
        let height = window.bounds.height
        globalSwipeStartInBand = loc.y >= height * Self.czfEdgeBandTop && loc.y <= height * Self.czfEdgeBandBottom
        globalSwipeStartInOutwardBand = loc.y >= height * Self.czfEdgeOutwardBandTop && loc.y <= height * Self.czfEdgeOutwardBandBottom
        if loc.x >= window.bounds.width - 44 {
            globalSwipeStartEdge = 2
        } else if loc.x <= 44 {
            globalSwipeStartEdge = 1
        } else {
            globalSwipeStartEdge = 0
        }
        globalSwipeStartX = loc.x
        return true
    }

    // 全局甩动手势只观察、不同步拦截：与 App 自己的手势同时识别
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return globalSwipeRecognizers.contains { $0 === gestureRecognizer } || czfLeftEdgePanRecognizers.contains { $0 === gestureRecognizer }
    }

    // MARK: - 边缘手势入口（悬浮边条窗 / 宿主窗口手势共用）
    private var dockIsOnRightSide: Bool {
        let screenWidth = keyWindow?.bounds.width ?? 0
        return (hostingController?.view.frame.midX ?? 0) > screenWidth / 2
    }

    // 动作确认震动：只在动作真正生效的点调用（守卫之后），
    // 一次手势最多一下，没生效不震。
    private func edgeCallbackBuzz() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // 右边缘手势改派（用户定 2026-10-25）：不再是小窗口/最大化，
    // 改成切换已打开的 App——往左滑=上一个，往右滑=下一个，按
    // 运行中列表（启动顺序）循环；只切前台，不改窗口状态（不强
    // 制最大化也不强制小窗口）。面板开着时不抢：面板自己的边缘
    // 互切（App↔源）处理。左边缘手势（App 面板/源面板开关）不
    // 动。宿主窗口手势与游客插件的 Darwin 通知都汇到这两个入
    // 口，动作在此判定。
    @objc public func czfEdgeRightInward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        czfSwitchRunningApp(step: -1)
    }

    @objc public func czfEdgeRightOutward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        czfSwitchRunningApp(step: +1)
    }

    // 已打开 App 循环切换：以台前 App 为基准（czfFrontmostApp），
    // 上一个/下一个按运行中列表顺序、首尾相接；主界面（没有台
    // 前 App）时往右=列表第一个、往左=列表最后一个。没运行 App
    // 或面板开着时不动。
    private func czfSwitchRunningApp(step: Int) {
        guard !apps.isEmpty, !isAppPanelOpen, !isSourcesPanelOpen else { return }
        // 单个 App：右缘轮换改成隐藏/显示切换（用户定 2026-10-25）。
        // 只有一个在跑时轮换目标永远是自己、看着像没反应；改成：
        // 可见时滑一下最小化（回宿主），已最小化时滑一下叫回来。
        // 多个 App 仍按原路循环切换。
        if apps.count == 1 {
            let only = apps[0]
            if czfFrontmostApp()?.appUUID == only.appUUID {
                minimizeWindow(uuid: only.appUUID)
            } else {
                guard bringMultitaskViewToFront(uuid: only.appUUID, from: nil) else { return }
            }
            edgeCallbackBuzz()
            return
        }
        let currentIndex = czfFrontmostApp().flatMap { front in
            apps.firstIndex(where: { $0.appUUID == front.appUUID })
        }
        let targetIndex: Int
        if let i = currentIndex {
            targetIndex = (i + step + apps.count) % apps.count
        } else {
            targetIndex = step > 0 ? 0 : apps.count - 1
        }
        let target = apps[targetIndex]
        // 切到大窗口：直接全屏调出来（用户定 2026-10-25）。
        // 通用带脉冲动画的路径在 1 大 1 小时盖不住小窗口（实测）；
        // 大窗口不走缩放脉冲（全屏窗脉冲多余），改走静默直提 + 重申最大化状态，
        // 并保留 LCMaxOneAppOnStage 的最小化他人行为；切到小窗口走原路径不变。
        // 但已最小化的大窗口不走静默直提：静默分支只调 z 序、不取消
        // 隐藏，滑了也出不来（最小化过的 App 右缘叫不回来的根因）；
        // 隐藏的目标改走带取消隐藏的通用路径（面板「打开」同款）。
        if let targetView = target.view,
           let targetVC = targetView._viewDelegate() as? DecoratedAppSceneViewController,
           targetVC.isMaximized,
           !targetView.isHidden, targetView.alpha >= 0.1,
           let targetWindow = targetView.window ?? targetView.superview?.window {
            passURLSchemeToView(targetView)
            if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") {
                minimizeAllWindows(except: targetVC)
            }
            bringViewToFront(targetView, in: targetWindow)
            maximizeWindow(uuid: target.appUUID)
            edgeCallbackBuzz()
        } else {
            guard bringMultitaskViewToFront(uuid: target.appUUID, from: nil) else { return }
            edgeCallbackBuzz()
        }
    }

    // 当前 App：层级最靠前、可见的运行中 App，纯按 z 序算，不以
    // “已最大化”优先——最大化不等于在最上：小窗口切到前台后会
    // 盖在最大化 App 上面。原来“见最大化就返回”会让台前判定卡
    // 在先启动的那个最大化 App 上，轮流切换时每次都算出同一个
    // 目标、看着像没切（v164 上报的 bug）。最小化中的（视图已
    // 隐藏）不算。
    private func czfFrontmostApp() -> DockAppModel? {
        var frontmost: DockAppModel?
        var frontmostZ = -1
        for app in apps {
            guard let view = app.view, !view.isHidden, view.alpha >= 0.1,
                  view._viewDelegate() is DecoratedAppSceneViewController else { continue }
            let z = view.superview?.subviews.firstIndex(where: { $0 === view }) ?? 0
            if z > frontmostZ {
                frontmostZ = z
                frontmost = app
            }
        }
        return frontmost
    }

    @objc public func czfEdgeLeftOutward() {
        guard Self.czfEdgeGesturesEnabled else { return }
        guard isVisible || !apps.isEmpty, !isDockHidden, !dockIsOnRightSide else { return }
        edgeCallbackBuzz()
        hideDockToSide()
    }

    // App 面板入口：左边缘往里拖（手指右移）调出（2026-10-23
    // 真机纠正对调：此前按"手指往左移"实现，与用户实际动作
    // 正好相反）。面板独立呈现，不联动快捷栏——栏藏着就保持
    // 藏着（用户定：调面板时不许把栏也带出来）。全屏同理，不
    // 用小窗口绕路（#91 的先还原小窗口已删）。触发收不到的
    // 根因在插件侧（系统左边缘手势截走触摸），已由插件的
    // sendEvent 触摸漏斗修复。
    // 两个面板当前是否打开（以面板视图 isHidden 为准，与呈现层同源）
    private var isAppPanelOpen: Bool {
        guard let host = czfPanelOverlayHost else { return false }
        return !host.view.isHidden
    }
    private var isSourcesPanelOpen: Bool {
        guard let host = czfSourcesOverlayHost else { return false }
        return !host.view.isHidden
    }

    // 面板动作防重复：同一次滑动可能被插件（Darwin）和宿主窗口
    // 识别器两条路各报一次（小窗口模式两边都收得到触摸），切换式
    // 开关下第二下会把刚打开的面板又关掉，还多震一下。
    // 分来源去重（行为底线不动：启用带、控件排除、切换式全不变）：
    // 同来源 0.4 秒内重复吞掉（各来源各算各的，不再互相吞掉对方
    // 的第二次滑动）；跨来源回声另防——任一面板刚由另一来源打开
    // （0.4 秒内），本次就是同一物理滑动的第二路信号，直接吞掉，
    // 不开了又关、不多震。面板内互切（switchPanels）仍用下面
    // 共用的 czfLastPanelActionAt，不走这两路。
    private var czfLastPanelActionAt = Date.distantPast
    private enum CZFPanelSignalSource { case host, funnel }
    // 节流按面板分开记（2026-11-04 左滑确定性修复）：两面板
    // 共用一个节流时，右滑刚开完 App 面板、马上左滑会被吞掉，
    // 看着像左滑失灵；分开后互不影响，关着时一次左滑必定开。
    // 几何（带宽、边缘宽、门槛）一律不动。
    private var czfLastHostAppPanelActionAt = Date.distantPast
    private var czfLastFunnelAppPanelActionAt = Date.distantPast
    private var czfLastAppPanelOpenedAt = Date.distantPast
    private var czfLastAppPanelOpenedSource: CZFPanelSignalSource?
    private var czfLastHostSourcesPanelActionAt = Date.distantPast
    private var czfLastFunnelSourcesPanelActionAt = Date.distantPast
    private var czfLastSourcesPanelOpenedAt = Date.distantPast
    private var czfLastSourcesPanelOpenedSource: CZFPanelSignalSource?

    @objc public func czfOpenAppPanel() {
        czfToggleAppPanel(source: .host)
    }

    @objc public func czfOpenAppPanelFromFunnel() {
        czfToggleAppPanel(source: .funnel)
    }

    private func czfToggleAppPanel(source: CZFPanelSignalSource) {
        guard Self.czfEdgeGesturesEnabled else { return }
        // 不再要求已打开 App/快捷栏可见：用户定任意位置（包括刚
        // 进 LiveContainer 的主界面）都要能调出面板，与源面板同
        // 待遇。呈现走 keyWindow 兜底（presentAllAppsPanel 内）。
        let now = Date()
        switch source {
        case .host:
            guard now.timeIntervalSince(czfLastHostAppPanelActionAt) > 0.4 else { return }
            czfLastHostAppPanelActionAt = now
        case .funnel:
            guard now.timeIntervalSince(czfLastFunnelAppPanelActionAt) > 0.4 else { return }
            czfLastFunnelAppPanelActionAt = now
        }
        if now.timeIntervalSince(czfLastAppPanelOpenedAt) < 0.4, czfLastAppPanelOpenedSource != source { return }
        edgeCallbackBuzz()
        // 切换式（用户要求）：面板已打开再滑一次就关掉，
        // 不再是只能滑开、关还得点按钮/点遮罩。
        if isAppPanelOpen {
            dismissPanelOverlay()
            return
        }
        czfLastAppPanelOpenedAt = now
        czfLastAppPanelOpenedSource = source
        presentAllAppsPanel()
    }

    // 源面板入口：左边缘往外弹（手指左移）调出（2026-10-23
    // 对调后，与往里拖的 App 面板对称）。故意不加 isVisible/
    // !apps 守卫：没打开任何 App、在主界面时也要能调出（用户
    // 明确要求）；呈现走 keyWindow 兜底。同样是切换式：已打开
    // 再滑一次关掉。
    @objc public func czfOpenSourcesPanel() {
        czfToggleSourcesPanel(source: .host)
    }

    @objc public func czfOpenSourcesPanelFromFunnel() {
        czfToggleSourcesPanel(source: .funnel)
    }

    private func czfToggleSourcesPanel(source: CZFPanelSignalSource) {
        guard Self.czfEdgeGesturesEnabled else { return }
        let now = Date()
        switch source {
        case .host:
            guard now.timeIntervalSince(czfLastHostSourcesPanelActionAt) > 0.4 else { return }
            czfLastHostSourcesPanelActionAt = now
        case .funnel:
            guard now.timeIntervalSince(czfLastFunnelSourcesPanelActionAt) > 0.4 else { return }
            czfLastFunnelSourcesPanelActionAt = now
        }
        if now.timeIntervalSince(czfLastSourcesPanelOpenedAt) < 0.4, czfLastSourcesPanelOpenedSource != source { return }
        edgeCallbackBuzz()
        if isSourcesPanelOpen {
            dismissSourcesOverlay()
            return
        }
        czfLastSourcesPanelOpenedAt = now
        czfLastSourcesPanelOpenedSource = source
        presentSourcesPanel()
    }


    // 键盘监听（3.8.296）：只注册一次；面板打开时键盘弹出/收起，
    // 按键盘高度整体上移/落下面板，搜索框始终露在键盘上面。
    private func czfStartKeyboardObserving() {
        guard !czfKeyboardObserversAdded else { return }
        czfKeyboardObserversAdded = true
        NotificationCenter.default.addObserver(self, selector: #selector(czfKeyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(czfKeyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func czfKeyboardWillShow(_ note: Notification) {
        // 键盘 frame 在 userInfo 里是 NSValue（不是 CGRect），必须走
        // cgRectValue 取——直接 as? CGRect 取不到，会静默失效。
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        czfKeyboardHeight = value.cgRectValue.height
        czfShiftOpenPanelsForKeyboard()
    }

    @objc private func czfKeyboardWillHide(_ note: Notification) {
        czfKeyboardHeight = 0
        czfShiftOpenPanelsForKeyboard()
    }

    // 面板打开时的顶沿 Y（键盘弹出时整体上移键盘高度，搜索框露在
    // 键盘上面；键盘收起归零回到底部 45%+48pt 的位置）。
    private func czfPanelOpenY(panelHeight: CGFloat, in bounds: CGRect) -> CGFloat {
        bounds.height - panelHeight - czfKeyboardHeight
    }

    // 键盘弹出/收起时，把已打开的面板整体上移/落下（只动已打开的；
    // 没开的面板下次弹出时按 czfPanelOpenY 算位置，不用这里管）。
    private func czfShiftOpenPanelsForKeyboard() {
        for (host, _) in [(czfPanelOverlayHost, czfPanelOverlayBackdrop), (czfSourcesOverlayHost, czfSourcesOverlayBackdrop)] {
            guard let host, !host.view.isHidden, let window = host.view.superview else { continue }
            let panelHeight = host.view.frame.height
            let targetY = czfPanelOpenY(panelHeight: panelHeight, in: window.bounds)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                host.view.frame.origin.y = targetY
            }
        }
    }


    // 建好手势面板覆盖层（只建一次，常驻窗口待命，和快捷栏同一个生命周期）。
    // #89 是每次左滑现建 SwiftUI 视图树：首帧渲染慢，滑完要等一下才动，
    // 体感像失灵；且开/关状态只认存着的引用，视图一旦被外部摘掉引用还
    // 非空，之后永远弹不出（小窗口"有时行有时不行"）。常驻后开/关只改
    // 可见性和位置，状态以视图 isHidden 为准，不再被旧引用毒化。
    private func ensurePanelOverlay(in window: UIWindow) {
        // 键盘监听只注册一次（3.8.296）：面板搜索框获焦弹键盘时按
        // 键盘高度上移面板，关面板时收键盘。
        czfStartKeyboardObserving()
        if let host = czfPanelOverlayHost, let backdrop = czfPanelOverlayBackdrop {
            // 已建过：若被挪出当前窗口（窗口/场景切换），搬回当前窗口
            if host.view.superview !== window {
                window.addSubview(backdrop)
                window.addSubview(host.view)
            }
            return
        }
        // 状态不完整（只剩一半）：清掉重建，避免留孤儿视图
        czfPanelOverlayHost?.view.removeFromSuperview()
        czfPanelOverlayBackdrop?.removeFromSuperview()
        czfPanelOverlayHost = nil
        czfPanelOverlayBackdrop = nil
        // 背景遮罩：点任意空白处关闭
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backdrop.alpha = 0
        backdrop.isHidden = true
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.czfPanelBackdropTapped)))
        window.addSubview(backdrop)
        // 面板本体：底部 45% 高 + 48pt，上圆角（75% 版 2026-10-23 当晚被
        // 用户真机否决：又高又肿，且整条盖死源面板手势起手带；
        // 60% 版 2026-11-06 用户看样板图仍嫌高，50% 版同日用户
        // 又令降到 45%，再推一版；3.8.296 用户令再调高 48pt——
        // 固定区图标被面板顶沿压住发糊，顶沿抬高 48pt 留出余量）
        let rootView = AnyView(
            AllAppsListView()
                .environmentObject(self)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissPanelOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        // 3.8.292：宿主底色放透明（与源面板宿主 289 同款）——App
        // 面板走液态玻璃时，玻璃要直接采客 App 当底。
        host.view.backgroundColor = .clear
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.45 + 48)
        host.view.layer.cornerRadius = 20
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
        // 下滑关闭：面板宿主挂拖动手势（只认顶部标题区起手，不抢
        // 列表滚动，起手判定在 gestureRecognizerShouldBegin）
        let drag = UIPanGestureRecognizer(target: self, action: #selector(self.czfPanelDragged(_:)))
        drag.delegate = self
        host.view.addGestureRecognizer(drag)
        // 边缘横滑切源面板（用户定）：面板打开时遮罩盖全屏、原来的
        // 边缘手势被挡，只能靠面板自己身上的手势切；UIScreenEdgePan
        // 只认贴边起手，不抢面板里横滑条的滚动；遮罩和面板本体各
        // 挂一个（一个手势只能挂一个视图）
        let edgeToSources = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfAppPanelEdgeSwitched(_:)))
        edgeToSources.edges = .left
        backdrop.addGestureRecognizer(edgeToSources)
        let edgeToSourcesOnPanel = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfAppPanelEdgeSwitched(_:)))
        edgeToSourcesOnPanel.edges = .left
        host.view.addGestureRecognizer(edgeToSourcesOnPanel)
        czfPanelOverlayBackdrop = backdrop
        czfPanelOverlayHost = host
    }

    // 面板要进的窗口：台前 App 最大化时必须用它的窗口——
    // 宿主窗（栏所在窗）会被全屏游客窗口盖住，面板在里面
    // 开了也看不见（最大化根本用不了手势面板、没法调 App）。
    // 非最大化时沿用宿主窗，不动原有行为。
    private var czfPanelTargetWindow: UIWindow? {
        if let front = czfFrontmostApp(),
           let view = front.view,
           let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
           vc.isMaximized,
           let w = view.window {
            return w
        }
        return hostingController?.view.window ?? keyWindow
    }

    private func presentAllAppsPanel() {
        DispatchQueue.main.async {
            guard let window = self.czfPanelTargetWindow else { return }
            // 两个面板互斥：开这个先关那个
            self.dismissSourcesOverlay()
            self.ensurePanelOverlay(in: window)
            guard let host = self.czfPanelOverlayHost, let backdrop = self.czfPanelOverlayBackdrop else { return }
            // 每次调用都强制对齐到打开状态，不看旧状态早退：旧状态可能
            // 与真实显示脱节（isHidden 为 false 但 frame 停在屏外/被盖住，
            // 表现为"滑一次没出来、再滑一次才出来"）。搬顶层、摆正、
            // 切可见、动画到目标位，一次调用即恢复；已打开时动画终点
            // 与当前位相同，无可见副作用。
            // 计数 +1：面板视图据此滚回顶部（每次调出都是初始状态）
            self.czfAppPanelOpenCounter += 1
            window.bringSubviewToFront(backdrop)
            window.bringSubviewToFront(host.view)
            let b = window.bounds
            let panelHeight = b.height * 0.45 + 48
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != panelHeight {
                host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: panelHeight)
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = CGRect(x: 0, y: self.czfPanelOpenY(panelHeight: panelHeight, in: b), width: b.width, height: panelHeight)
            }
        }
    }

    @objc private func czfPanelBackdropTapped() {
        dismissPanelOverlay()
    }

    // 面板下滑关闭的起手限制：两面板都认固定栏整条（标题行
    // 已去掉后约 58pt，取 64：顶边 16 + 图标 40 + 底边 2；
    // 再往下是运行条（约 66 起），不扩到它），用户 2026-11-03
    // 定固定栏往下滑动隐藏面板；源面板 3.8.284 也加了固定栏，
    // 与 App 面板同限。面板内的列表滚动一点不受影响；其余
    // 手势一律放行。
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let hostView = gestureRecognizer.view,
           hostView === czfPanelOverlayHost?.view || hostView === czfSourcesOverlayHost?.view {
            let topLimit: CGFloat = 64
            guard gestureRecognizer.location(in: hostView).y < topLimit else { return false }
            // 下滑关闭只认向下为主的初动：原来顶部区内任何方向
            // 的移动都让下滑手势先认——横滑被它认走后全局手势
            // 失效（面板上左滑有时不出），点按被它取消（收起
            // 点着没反应）。横滑交给全局手势，点按不受影响。
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let t = pan.translation(in: hostView)
                return t.y > abs(t.x) && t.y > 0
            }
            return true
        }
        return true
    }

    // 面板下滑关闭（两个面板共用，按手势挂的宿主区分）：拖动跟随
    // 手指，松手时位移过 90 或下滑速度过 500 就关，否则弹回。
    @objc private func czfPanelDragged(_ gesture: UIPanGestureRecognizer) {
        guard let hostView = gesture.view, let container = hostView.superview else { return }
        let isSources = hostView === czfSourcesOverlayHost?.view
        let backdrop = isSources ? czfSourcesOverlayBackdrop : czfPanelOverlayBackdrop
        let panelHeight = hostView.frame.height
        // 拖回落点按键盘高度算（3.8.296）：键盘弹出时面板整体上移过，
        // 落点也要上移，否则松手弹回会把面板压回键盘底下。
        let openY = czfPanelOpenY(panelHeight: panelHeight, in: container.bounds)
        switch gesture.state {
        case .changed:
            let dy = max(0, gesture.translation(in: container).y)
            hostView.frame.origin.y = openY + dy
            backdrop?.alpha = max(0, 1 - dy / panelHeight)
        case .ended, .cancelled:
            let dy = max(0, gesture.translation(in: container).y)
            let velocityY = gesture.velocity(in: container).y
            if dy > 90 || velocityY > 500 {
                if isSources {
                    dismissSourcesOverlay()
                } else {
                    dismissPanelOverlay()
                }
            } else {
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
                    hostView.frame.origin.y = openY
                    backdrop?.alpha = 1
                }
            }
        default:
            break
        }
    }

    // 关闭手势面板覆盖层：滑出后切回隐藏待命（不摘除、不销毁）。
    // 背景点击、面板内关闭/启动/最小化/小窗口按钮（经 czfPanelClose 注入）
    // 都会走到这里。
    private func dismissPanelOverlay() {
        guard let host = czfPanelOverlayHost, let backdrop = czfPanelOverlayBackdrop, !host.view.isHidden else { return }
        let height = host.view.frame.height
        // 3.8.296：关面板落到底部（y = 屏高）再藏，不再按 height 相对
        // 下移——键盘弹出时面板整体上移过，相对下移 height 会停在
        // 屏高 - 键盘高度处、露半截在屏内。
        let b = host.view.superview?.bounds ?? UIScreen.main.bounds
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame = CGRect(x: 0, y: b.height, width: host.view.frame.width, height: height)
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
            // 关面板时顺带收键盘（3.8.296）：搜索框获焦后关面板，
            // TextField 随宿主隐藏但不 resign，键盘会孤儿留在屏上。
            // 放 completion 里——先关面板再收键盘，避免键盘收起的
            // 移位回调与关面板动画打架。
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
    }

    // MARK: - 源面板覆盖层（与 App 面板同构：常驻待命、强制对齐呈现）

    private func ensureSourcesOverlay(in window: UIWindow) {
        // 键盘监听只注册一次（3.8.296，见 ensurePanelOverlay）。
        czfStartKeyboardObserving()
        if let host = czfSourcesOverlayHost, let backdrop = czfSourcesOverlayBackdrop {
            if host.view.superview !== window {
                window.addSubview(backdrop)
                window.addSubview(host.view)
            }
            return
        }
        czfSourcesOverlayHost?.view.removeFromSuperview()
        czfSourcesOverlayBackdrop?.removeFromSuperview()
        czfSourcesOverlayHost = nil
        czfSourcesOverlayBackdrop = nil
        let backdrop = UIView(frame: window.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backdrop.alpha = 0
        backdrop.isHidden = true
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.czfSourcesBackdropTapped)))
        window.addSubview(backdrop)
        let rootView = AnyView(
            SourcesPanelView()
                .environmentObject(self)
                // 3.8.311：App 设置页（LCAppSettingsView）要
                // SharedModel 作 @EnvironmentObject，面板是独立
                // hosting，不注会崩；注的是全 App 同一个实例。
                .environmentObject(DataManager.shared.model)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissSourcesOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        // 3.8.289：宿主底色放透明——源面板走液态玻璃时，玻璃
        // 要直接采客 App 当底；不放透明玻璃会被宿主默认底色盖住。
        // 非玻璃系统下，面板底由 SourcesPanelView 里
        // systemBackground 兜底，外观与原来一致。
        host.view.backgroundColor = .clear
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.45 + 48)
        host.view.layer.cornerRadius = 20
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
        // 下滑关闭：与 App 面板共用同一个拖动处理器
        let drag = UIPanGestureRecognizer(target: self, action: #selector(self.czfPanelDragged(_:)))
        drag.delegate = self
        host.view.addGestureRecognizer(drag)
        // 边缘横滑切 App 面板（用户定，与 App 面板那侧镜像）：右缘
        // 往左滑切回 App 面板，同样只认贴边起手、不抢横滑条滚动
        let edgeToApps = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfSourcesPanelEdgeSwitched(_:)))
        edgeToApps.edges = .right
        backdrop.addGestureRecognizer(edgeToApps)
        let edgeToAppsOnPanel = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.czfSourcesPanelEdgeSwitched(_:)))
        edgeToAppsOnPanel.edges = .right
        host.view.addGestureRecognizer(edgeToAppsOnPanel)
        czfSourcesOverlayBackdrop = backdrop
        czfSourcesOverlayHost = host
    }

    private func presentSourcesPanel() {
        DispatchQueue.main.async {
            guard let window = self.czfPanelTargetWindow else { return }
            // 两个面板互斥：开这个先关那个
            self.dismissPanelOverlay()
            self.ensureSourcesOverlay(in: window)
            guard let host = self.czfSourcesOverlayHost, let backdrop = self.czfSourcesOverlayBackdrop else { return }
            // 计数 +1：面板视图据此刷新源数据（覆盖层常驻，onAppear 不重来）
            self.czfSourcesPanelOpenCounter += 1
            window.bringSubviewToFront(backdrop)
            window.bringSubviewToFront(host.view)
            let b = window.bounds
            let panelHeight = b.height * 0.45 + 48
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != panelHeight {
                host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: panelHeight)
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = CGRect(x: 0, y: self.czfPanelOpenY(panelHeight: panelHeight, in: b), width: b.width, height: panelHeight)
            }
        }
    }

    // 面板互切（用户定）：App 面板左缘往右滑切源面板、源面板右缘
    // 往左滑切 App 面板。面板打开时遮罩盖全屏、原来的边缘手势被
    // 挡，只能靠面板自己身上的边缘手势切；切换时遮罩不闪（新遮
    // 罩直接显到 1、旧遮罩动画完再藏），两面板同时上下滑（旧的
    // 下去、新的上来），看着像翻页，不是一关一开；0.4 秒节流和
    // 开面板同款，防连滑叠动画。
    private func switchPanels(toSources: Bool) {
        DispatchQueue.main.async {
            guard Self.czfEdgeGesturesEnabled else { return }
            let now = Date()
            guard now.timeIntervalSince(self.czfLastPanelActionAt) > 0.4 else { return }
            guard toSources ? self.isAppPanelOpen : self.isSourcesPanelOpen else { return }
            guard let window = self.czfPanelTargetWindow else { return }
            self.czfLastPanelActionAt = now
            self.edgeCallbackBuzz()
            if toSources {
                self.ensureSourcesOverlay(in: window)
            } else {
                self.ensurePanelOverlay(in: window)
            }
            guard let oldHost = toSources ? self.czfPanelOverlayHost : self.czfSourcesOverlayHost,
                  let oldBackdrop = toSources ? self.czfPanelOverlayBackdrop : self.czfSourcesOverlayBackdrop,
                  let newHost = toSources ? self.czfSourcesOverlayHost : self.czfPanelOverlayHost,
                  let newBackdrop = toSources ? self.czfSourcesOverlayBackdrop : self.czfPanelOverlayBackdrop else { return }
            let b = window.bounds
            let panelHeight = b.height * 0.45 + 48
            if toSources {
                self.czfSourcesPanelOpenCounter += 1
            } else {
                self.czfAppPanelOpenCounter += 1
            }
            window.bringSubviewToFront(newBackdrop)
            window.bringSubviewToFront(newHost.view)
            newBackdrop.frame = b
            newBackdrop.isHidden = false
            newBackdrop.alpha = 1
            newHost.view.isHidden = false
            if newHost.view.frame.height != panelHeight {
                newHost.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: panelHeight)
            }
            let oldHeight = oldHost.view.frame.height
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                // 3.8.296：旧面板落到底部（y = 屏高）再藏，不按 height 相对
                // 下移——键盘弹出时旧面板上移过，相对下移会露半截。
                oldHost.view.frame = CGRect(x: 0, y: b.height, width: oldHost.view.frame.width, height: oldHeight)
                newHost.view.frame = CGRect(x: 0, y: self.czfPanelOpenY(panelHeight: panelHeight, in: b), width: b.width, height: panelHeight)
            } completion: { _ in
                oldBackdrop.isHidden = true
                oldHost.view.isHidden = true
            }
        }
    }

    @objc private func czfAppPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // 左缘互切只认往右（向里）：注释定的方向，代码原来不验，
        // 往外方向的滑动也会切到源面板。
        guard gesture.translation(in: gesture.view).x > 0 else { return }
        switchPanels(toSources: true)
    }

    @objc private func czfSourcesPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        // 右缘互切只认往左（向里）
        guard gesture.translation(in: gesture.view).x < 0 else { return }
        switchPanels(toSources: false)
    }

    @objc private func czfSourcesBackdropTapped() {
        dismissSourcesOverlay()
    }

    private func dismissSourcesOverlay() {
        guard let host = czfSourcesOverlayHost, let backdrop = czfSourcesOverlayBackdrop, !host.view.isHidden else { return }
        let height = host.view.frame.height
        // 3.8.296：同 App 面板——落到底部再藏（键盘上移过时相对下移
        // 会露半截），completion 里顺带收键盘（见 dismissPanelOverlay）。
        let b = host.view.superview?.bounds ?? UIScreen.main.bounds
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame = CGRect(x: 0, y: b.height, width: host.view.frame.width, height: height)
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
    }

    // 手势已改走宿主悬浮边条窗，不再用插件：清掉旧版本部署到两个全局
    // Tweaks 根目录的手势插件文件，避免它继续随游客 App 加载。
    // 静态方法：宿主一启动（AppDelegate）就调，赶在任何游客 App 启动之前。
    // 管理器初始化时也会再调一次（幂等）。
    // 游客 App 是独立进程，插件的手势信号通过 Darwin 跨进程通知送达这里
    // 游客点按置顶的宿主侧观察者：游客每次触摸按下发 czf.window.touch.<bid>，
    // 宿主按名找到窗口静默置顶。注册记账防重复（同 bid 重装不重复注册；
    // 残留观察者也无害：触发时按 bid 现查，找不到就空操作）。
    private var czfTouchRaiseRegisteredBids: Set<String> = []
    private func czfRegisterTouchRaiseObserver(bundleId: String) {
        guard !czfTouchRaiseRegisteredBids.contains(bundleId) else { return }
        czfTouchRaiseRegisteredBids.insert(bundleId)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = "czf.window.touch.\(bundleId)"
        CFNotificationCenterAddObserver(center, observer, { _, observerPtr, cfName, _, _ in
            guard let observerPtr = observerPtr, let cfName = cfName else { return }
            let manager = Unmanaged<MultitaskDockManager>.fromOpaque(observerPtr).takeUnretainedValue()
            let notificationName = cfName.rawValue as String
            guard notificationName.hasPrefix("czf.window.touch.") else { return }
            let bid = String(notificationName.dropFirst("czf.window.touch.".count))
            DispatchQueue.main.async {
                manager.czfRaiseWindowForTouch(bundleId: bid)
            }
        }, name as CFString, nil, .deliverImmediately)
    }
    private func czfUnregisterTouchRaiseObserver(bundleId: String) {
        guard czfTouchRaiseRegisteredBids.remove(bundleId) != nil else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(rawValue: "czf.window.touch.\(bundleId)" as CFString), nil)
    }

    // 边缘手势信号观察者：游客边缘手势的 Darwin 信号（czf.dock.*）送达这里
    private func registerDockEdgeDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let names = ["czf.dock.rightInward", "czf.dock.rightOutward", "czf.dock.leftOutward", "czf.dock.openPanel", "czf.dock.openSources"]
        for name in names {
            CFNotificationCenterAddObserver(center, observer, { _, observerPtr, cfName, _, _ in
                guard let observerPtr = observerPtr, let cfName = cfName else { return }
                let manager = Unmanaged<MultitaskDockManager>.fromOpaque(observerPtr).takeUnretainedValue()
                let notificationName = cfName.rawValue as String
                DispatchQueue.main.async {
                    switch notificationName {
                    case "czf.dock.rightInward": manager.czfEdgeRightInward()
                    case "czf.dock.rightOutward": manager.czfEdgeRightOutward()
                    case "czf.dock.leftOutward": manager.czfEdgeLeftOutward()
                    case "czf.dock.openPanel": manager.czfOpenAppPanelFromFunnel()
                    case "czf.dock.openSources": manager.czfOpenSourcesPanelFromFunnel()
                    default: break
                    }
                }
            }, name as CFString, nil, .deliverImmediately)
        }
    }

    // 把手势插件拷到两个全局 Tweaks 根目录（随所有游客 App 加载），并强制签名。
    // 静态方法：宿主一启动（AppDelegate）就调，赶在任何游客 App 启动之前，
    // 避开签名缓存与启动抢跑。管理器初始化时也会再调一次（幂等）。
    static func deployDockGestureTweak() {
        // 手势不再作为独立插件下发（2026-10-24 用户亲定：别再注入）：
        // 手势代码已随 TweakLoader 编译进启动器，这里只清掉全局插件
        // 目录里残留的旧独立文件——不清的话 TweakLoader 还会把它
        // 当插件 dlopen，双份挂钩、手势触发两次。
        let fm = FileManager.default
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            try? fm.removeItem(at: folder.appendingPathComponent("CZFDockGesture.dylib"))
        }
    }

    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first else { return }
        
        keyWindow.gestureRecognizers?.removeAll { gesture in
            return gesture is UITapGestureRecognizer || gesture is UIScreenEdgePanGestureRecognizer
        }
        
        if isDockHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            leftEdgeGesture.delegate = self
            keyWindow.addGestureRecognizer(leftEdgeGesture)
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            rightEdgeGesture.delegate = self
            keyWindow.addGestureRecognizer(rightEdgeGesture)
        }
    }
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isDockHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }
        if gesture.state == .began {
            czfEdgeSwipeLatched = false
        }

        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)

        if swipeDistance > Constants.edgeSwipeThreshold, !czfEdgeSwipeLatched {
            czfEdgeSwipeLatched = true
            // 左边缘（屏幕边缘手势只能往里拖）= App 面板
            // （2026-10-23 对调后，与全局甩手判定一致）；
            // 右边缘：App 页（没有台前 App）且有运行中 App
            // 时切到 App（最近一个）；否则照旧唤出快捷栏。
            // 游客里台前有 App 时不动，免得和游客侧切换
            // 重复触发。
            if gesture.edges == .left {
                czfOpenAppPanel()
            } else if czfFrontmostApp() == nil, !apps.isEmpty {
                czfEdgeRightInward()
            } else {
                showDockFromHidden()
            }
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

extension Notification.Name {
    // 手势请求打开 App 面板（管理器发、栏视图收）
    static let czfOpenAllAppsPanel = Notification.Name("czfOpenAllAppsPanel")
}

// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    @State private var dragOffset = CGSize.zero
    @State private var isMoving: Bool = false
    @State private var showAllApps = false
    // sheet 路面板启动失败回传到这里弹：sheet dismiss 后面板
    // 视图已销毁，本地 alert 弹不出，只能宿主弹（见 AllAppsListView
    // 的 onLaunchError；覆盖层路不走这里，行为不动）。
    @State private var sheetLaunchError: String?
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            VStack(spacing: 8) {
                if dockManager.isCollapsed {
                    CollapsedDockView(isHidden: dockManager.isDockHidden)
                        .onTapGesture {
                            dockManager.toggleDockCollapse()
                        }
                } else {
                    VStack(spacing: 8) {
                        AllAppsButtonView()
                            .onTapGesture {
                                showAllApps = true
                            }
                        
                        CollapseButtonView()
                            .onTapGesture {
                                dockManager.toggleDockCollapse()
                            }
                        
                        MinimizeAllButtonView()
                            .onTapGesture {
                                dockManager.minimizeAllWindows()
                            }
                        
                        ForEach(dockManager.apps) { app in
                            AppIconView(app: app)
                        }
                        
                        CloseAllButtonView()
                            .onTapGesture {
                                dockManager.closeAllWindows()
                            }
                    }
                }
            }
            .padding(dynamicPadding)
            .sheet(isPresented: $showAllApps) {
                AllAppsListView(onLaunchError: { sheetLaunchError = $0 })
                    // 3.8.294：档位与 overlay 面板高度对齐（45%）：
                    // 原来 0.6 与面板 45% 不一致，同一份列表两种高度。
                    .presentationDetents([.fraction(0.45)])
                    .presentationDragIndicator(.visible)
            }
            // sheet 路面板启动失败提示（与面板本地 alert 同款文案）：
            // 宿主视图不随 sheet 销毁，错误回传到这里才能弹出来。
            .alert("提示", isPresented: Binding(get: { sheetLaunchError != nil }, set: { if !$0 { sheetLaunchError = nil } })) {
                Button("好") { sheetLaunchError = nil }
            } message: {
                Text(sheetLaunchError ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .czfOpenAllAppsPanel)) { _ in
                showAllApps = true
            }
            .onChange(of: dockManager.czfPanelOpenCounter) { _ in
                showAllApps = true
            }
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                } else {
                    content.background(
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.black.opacity(dockManager.isDockHidden ? 0.3 : 0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(dockManager.isDockHidden ? 0.1 : 0.3), lineWidth: 1)
                            )
                    )
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            .opacity(dockManager.isDockHidden ? 0.0 : 1.0)
            .offset(dragOffset)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }



        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 5)
            .onChanged { value in
                self.isMoving = true
                self.dragOffset = value.translation
            }
            .onEnded { value in
                self.isMoving = true

                let hcFrame = dockManager.hostingController?.view.frame ?? .zero
                
                let currentPhysicalFrame = hcFrame.offsetBy(dx: self.dragOffset.width, dy: self.dragOffset.height)
                
                if dockManager.isPositionChangeGesture(for: hcFrame, translation: value.translation) {
                    let screenBounds = dockManager.keyWindow!.bounds
                    let targetX = dockManager.calculateTargetX(isDockHidden: false, isOnRightSide: currentPhysicalFrame.midX > screenBounds.width / 2, dockWidth: dockManager.dockWidth, screenWidth: screenBounds.width)
                    
                    let safeAreaInsets = dockManager.safeAreaInsets
                    let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                    let minY = safeAreaInsets.top + dockVerticalMargin
                    let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                    let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                    
                    let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                    
                    let newOffset = CGSize(
                        width: finalPhysicalPosition.x - hcFrame.origin.x,
                        height: finalPhysicalPosition.y - hcFrame.origin.y
                    )
                    
                    let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                    
                    withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = newOffset
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                        dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                        
                        self.dragOffset = .zero
                        
                        self.isMoving = false
                    }
                    return
                }
                
                if dockManager.handleSwipeToHideOrShowGesture(for: hcFrame, translation: value.translation) {
                    withAnimation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                        self.dragOffset = .zero
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + MultitaskDockManager.Constants.longAnimationDuration) {
                        self.isMoving = false
                    }
                    return
                }
                
                let screenBounds = dockManager.keyWindow!.bounds
                let safeAreaInsets = dockManager.safeAreaInsets
                let dockVerticalMargin = MultitaskDockManager.Constants.dockVerticalMargin
                let minY = safeAreaInsets.top + dockVerticalMargin
                let maxY = screenBounds.height - safeAreaInsets.bottom - currentPhysicalFrame.height - dockVerticalMargin
                let targetY = max(minY, min(maxY, currentPhysicalFrame.origin.y))
                
                let targetX: CGFloat

                let isOnRightSide = hcFrame.origin.x > screenBounds.width / 2
                targetX = dockManager.calculateTargetX(isDockHidden: dockManager.isDockHidden, isOnRightSide: isOnRightSide, dockWidth: currentPhysicalFrame.width, screenWidth: screenBounds.width)
                
                let finalPhysicalPosition = CGPoint(x: targetX, y: targetY)
                
                let newOffset = CGSize(
                    width: finalPhysicalPosition.x - hcFrame.origin.x,
                    height: finalPhysicalPosition.y - hcFrame.origin.y
                )
                
                let animationDuration = MultitaskDockManager.Constants.longAnimationDuration
                
                withAnimation(.spring(response: animationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping)) {
                    self.dragOffset = newOffset
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration) {
                    dockManager.updateFrameAfterAnimation(finalOffset: newOffset)
                    
                    self.dragOffset = .zero
                    
                    self.isMoving = false
                }
            }
        )
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isCollapsed)
        .animation(.spring(response: MultitaskDockManager.Constants.standardAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.isDockHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    let isHidden: Bool
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            // 蓝色渐变改平实心蓝：与面板主按钮同语言（渐变是旧
            // 糖果皮的一部分）；隐藏态靠透明度压暗的语义不变
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue.opacity(isHidden ? 0.5 : 0.9))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Group {
                if isHidden {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.system(size: dockManager.adaptiveIconSize * 0.35, weight: .bold))
                } else {
                    Image(systemName: "chevron.up")
                        .foregroundColor(.white)
                        .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .bold))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(isHidden ? 0.2 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isHidden ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// dock 小按钮底色/图标色：必须跟底板实际渲染走——v149 回归
// 教训：白底白字只在深色底板上可见；iOS 26 液态玻璃底板是
// 浅色磨砂，白按钮直接隐身（位置还在、能点但看不见）。玻璃
// 下用状态栏条同款浅灰底 + 深色图标，深色底板下用半透明
// 浅底 + 白图标，跟底板取同一个判断条件
private enum CZFDockButtonStyle {
    static var tile: Color {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            return Color(.systemGray5)
        }
        return Color.white.opacity(0.15)
    }
    static var glyph: Color {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            return .primary
        }
        return .white
    }
}

// MARK: - Collapse Button View
@available(iOS 16.0, *)
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // #12/#14：跟底板走（见 CZFDockButtonStyle，玻璃下浅灰
        // 底 + 深色图标，深色底板下半透明浅底 + 白图标）
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(CZFDockButtonStyle.tile)
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "chevron.down")
                .foregroundColor(CZFDockButtonStyle.glyph)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Minimize All Button View
@available(iOS 16.0, *)
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // #12/#14：同收起钮，跟底板走（见 CZFDockButtonStyle）
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(CZFDockButtonStyle.tile)
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundColor(CZFDockButtonStyle.glyph)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
    }
}

// MARK: - All Apps Button View
@available(iOS 16.0, *)
struct AllAppsButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    private let appIcon = UIImage(named: "DockAppIcon")
    
    var body: some View {
        ZStack {
            if let icon = appIcon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.8))
                    .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

                Image(systemName: "apps.iphone")
                    .foregroundColor(.white)
                    .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Close All Button (red X)
@available(iOS 16.0, *)
struct CloseAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        // 与面板「关闭全部」同款：浅红底 + 红图标（原实心红块
        // 太重）；dock 底板是深色，红色透明度比面板略提一档保识别
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.25))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)

            Image(systemName: "xmark")
                .foregroundColor(.red)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
    }
}

// 手势面板（窗口覆盖层方式）专用的关闭通道：覆盖层不是模态呈现，
// SwiftUI 的 dismiss 在那里无效。覆盖层注入关闭动作，面板内按钮统一走
// closePanel()：有注入走注入（覆盖层），没注入走 dismiss（点蓝图标的 sheet）。
private struct CZFPanelCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var czfPanelClose: (() -> Void)? {
        get { self[CZFPanelCloseKey.self] }
        set { self[CZFPanelCloseKey.self] = newValue }
    }
}

// MARK: - All Apps List View
// 面板顶部固定 App 的存储（用户定）：长按列表行固定/取消固定，
// 按实例记：键是“包名_数据文件夹名（dataUUID）”，与图标缓存
// 同款写法。只按包名记会把同 App 多开的全部实例一起固定
// （用户实证：固定一个 Muse，固定区出现两个 Muse）。
// 注意：删 App 重装会换数据文件夹，固定不跟过去（只丢固定，
// 不丢数据）；平时更新不换文件夹，固定不受影响。
final class CZFPinnedAppsStore: ObservableObject {
    static let shared = CZFPinnedAppsStore()
    @Published private(set) var pinnedIds: [String] = []
    private let defaultsKey = "CZFPinnedPanelApps"
    private let migratedKey = "CZFPinnedPanelAppsMigratedV2"
    init() {
        pinnedIds = LCUtils.appGroupUserDefault.stringArray(forKey: defaultsKey) ?? []
    }
    /// 固定键：实例粒度。dataUUID 是数据文件夹名，多开各实例不同；
    /// 为空时退到“包名_”（该模型无容器、跑不起来，撞键也无实际影响）。
    static func pinKey(for app: LCAppModel) -> String {
        "\(app.appInfo.bundleIdentifier() ?? "")_\(app.appInfo.dataUUID ?? "")"
    }
    /// 入参直接是模型对象，不再传裸字符串——传错键（比如包名）
    /// 就是这次 bug 的根源，API 上直接堵死。
    func isPinned(_ app: LCAppModel) -> Bool { pinnedIds.contains(Self.pinKey(for: app)) }
    func toggle(_ app: LCAppModel) {
        let key = Self.pinKey(for: app)
        if let idx = pinnedIds.firstIndex(of: key) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.append(key)
        }
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
    /// 3.8.291：源固定键——`"src:" + 包名`，与已装 App 的
    /// “包名_dataUUID”键共存于同一 CZFPinnedPanelApps 列表
    ///（288 的备份白名单已含此键，源固定项自动随导出备份，
    /// 无需另加）。冒号不会出现在包名里，不会与已装键撞。
    /// 源 App 无 dataUUID、无 LCAppModel，只能按包名记
    ///（多开不适用，源 App 本来就没有实例概念）。
    static func sourcePinKey(for app: AltStoreSourceApp) -> String {
        "src:\(app.bundleIdentifier)"
    }
    func isSourcePinned(_ app: AltStoreSourceApp) -> Bool { pinnedIds.contains(Self.sourcePinKey(for: app)) }
    func toggleSourcePin(_ app: AltStoreSourceApp) {
        let key = Self.sourcePinKey(for: app)
        if let idx = pinnedIds.firstIndex(of: key) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.append(key)
        }
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
    /// 固定区拖动换位（用户 2026-11-03 定：按住图标拖到目标
    /// 位置松手）：to 是换位后该项应占的下标（先删后插，
    /// 与 SwiftUI List 的 move 语义一致）；顺序即时落盘。
    func movePinned(from source: Int, to destination: Int) {
        guard source != destination,
              pinnedIds.indices.contains(source),
              destination >= 0, destination < pinnedIds.count else { return }
        let key = pinnedIds.remove(at: source)
        pinnedIds.insert(key, at: destination)
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }

    // 3.8.316：导入设置后重读——UserDefaults 被外部写回后内存
    // 里的 pinnedIds 还是旧的，界面看着像没恢复；跟排序的
    // reloadSortSettings 同款，导入时调一下即直接生效。
    func reload() {
        pinnedIds = LCUtils.appGroupUserDefault.stringArray(forKey: defaultsKey) ?? []
    }
    /// 旧版按包名存的固定项迁移（只跑一次）：单实例的包名直转
    /// 成该实例的键（用户的固定保留）；多实例的包名无法断定
    /// 当初固定的是哪一个，原键保留不猜（解析时查不到自然掉，
    /// 不删数据）；已删 App 的残留键同样保留，不主动清掉。
    /// 模型表为空时不跑、不记迁移完成（等面板下次打开模型到了再跑）。
    // 3.8.294：迁移只转换、不删除——匹配不上的旧键原样保留。
    // 原来“多实例或查无此 App 一律丢弃”，模型表还在加载（不全）
    // 时跑一次就会把固定过的 App 永久删掉；固定数据丢了不可逆，
    // 残留键留着无害（解析时查不到自然掉，不占地方也不报错）。
    func migrateLegacyPins(models: [LCAppModel]) {
        guard !LCUtils.appGroupUserDefault.bool(forKey: migratedKey) else { return }
        guard !models.isEmpty else { return }
        var migrated: [String] = []
        for entry in pinnedIds {
            // 3.8.291：源固定项（"src:" 前缀）不参与旧键迁移，
            // 原样保留——它本来就不是按包名存的旧键，模型表里
            // 也永远查不到（否则下次开面板就被当残留清掉）。
            if entry.hasPrefix("src:") {
                if !migrated.contains(entry) { migrated.append(entry) }
                continue
            }
            if models.contains(where: { Self.pinKey(for: $0) == entry }) {
                if !migrated.contains(entry) { migrated.append(entry) }
                continue
            }
            let sameBundle = models.filter { ($0.appInfo.bundleIdentifier() ?? "") == entry }
            if sameBundle.count == 1, let only = sameBundle.first {
                let key = Self.pinKey(for: only)
                if !migrated.contains(key) { migrated.append(key) }
                continue
            }
            // 多实例（sameBundle.count > 1）或查无此 App：原样保留，
            // 不删——模型表可能还没加载完，删了就找不回来；下次
            // 解析时查不到自然掉，不影响显示也不报错。
            if !migrated.contains(entry) { migrated.append(entry) }
        }
        pinnedIds = migrated
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
        LCUtils.appGroupUserDefault.set(true, forKey: migratedKey)
    }
}

// 面板顶部固定区：直接贴面板底色排版，不套灰卡；图标
// 横排，点按打开；没固定过时给一行提示怎么固定。
// 视觉对齐（2026-10-24）：面板三段统一外边距 16、内容列
// 对齐到 26（外 16 + 内 10，与运行条、列表行图标列同线）、
// 段间距统一 10；固定区图标行单独内缩 10，标题行不动
// （标题对齐卡片背景边，图标对齐图标列）。
// 固定区拖动换位的 DropDelegate：拖过目标图标即换位（松手
// 即定，不用等放下才动）；拖的键用 @State 传，不读 provider
// 的异步加载——dropEntered 是同步回调，读 provider 来不及。
// 拖出目标外取消时不调 performDrop，键残留无害：下一次拖
// 动起拖即覆盖，dropEntered 只在拖动进行中才触发。
@available(iOS 16.0, *)
private struct CZFPinnedReorderDelegate: DropDelegate {
    let targetIndex: Int
    let store: CZFPinnedAppsStore
    @Binding var draggedKey: String?

    func dropEntered(info: DropInfo) {
        guard let draggedKey = draggedKey,
              store.pinnedIds.indices.contains(targetIndex),
              store.pinnedIds[targetIndex] != draggedKey,
              let from = store.pinnedIds.firstIndex(of: draggedKey) else { return }
        store.movePinned(from: from, to: targetIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKey = nil
        return true
    }
}

@available(iOS 16.0, *)
struct PinnedAppsStripView: View {
    @ObservedObject var sortManager = LCAppSortManager.shared
    @ObservedObject var pinnedStore = CZFPinnedAppsStore.shared
    let onLaunch: (LCAppModel) -> Void
    // 3.8.284：空态提示文案可改——App 面板用默认句，源面板
    // 下面没有可固定的行，默认句会误导，调用方传自己的
    // 3.8.287：注意——属性这里不能带默认值。带默认值的 let
    // 在 init 体跑起来时已经算初始化过一次，init 里再写
    // self.emptyHint = emptyHint 就是第二次初始化，构建 334
    // 原话 `immutable value 'self.emptyHint' may only be
    // initialized once`。默认值放下面 init 的参数上（调用
    // 方不传时走它），属性本身只声明不赋值。
    let emptyHint: String
    // 3.8.291：源固定项的解析与安装。App 面板没有源数据，
    // 不传（nil）时源固定项直接跳过渲染；源面板传 viewModel
    // 的查找闭包 + installFromPanel。属性本身不带默认值
    //（见上面 3.8.287 的教训），默认值只放 init 参数上。
    let sourceAppResolver: ((String) -> AltStoreSourceApp?)?
    let onInstallSourceApp: ((AltStoreSourceApp) -> Void)?

    // 3.8.286：显式 init——光加带默认值的存储属性不够，
    // 构建 333 报 `extra argument 'emptyHint' in call`：调
    // 用方传 emptyHint 时编译器不认（默认成员初始化没把它
    // 捡进来）。直接把 init 写明，两处调用（App 面板只传
    // onLaunch、源面板传 onLaunch + emptyHint）都走它；
    // @ObservedObject/@State 照默认值走，不用在这里写。
    init(onLaunch: @escaping (LCAppModel) -> Void, emptyHint: String = "长按下面的 App 可以固定到这里", sourceAppResolver: ((String) -> AltStoreSourceApp?)? = nil, onInstallSourceApp: ((AltStoreSourceApp) -> Void)? = nil) {
        self.onLaunch = onLaunch
        self.emptyHint = emptyHint
        self.sourceAppResolver = sourceAppResolver
        self.onInstallSourceApp = onInstallSourceApp
    }

    // 3.8.291：固定区统一项——已装 App 与源固定项按固定顺序
    // 混排（同一 CZFPinnedPanelApps 列表）。源项按包名在各源
    // 里找，找不到（源已删/还没加载完）就跳过，不崩不留坏块。
    private enum PinnedStripItem {
        case installed(LCAppModel)
        case source(AltStoreSourceApp)

        // 换位时 ForEach 的稳定身份：用固定键本身。源 App 每次
        // 刷新都会生成新的 UUID id，按实例判等会抖。
        var pinKey: String {
            switch self {
            case .installed(let app):
                return CZFPinnedAppsStore.pinKey(for: app)
            case .source(let app):
                return CZFPinnedAppsStore.sourcePinKey(for: app)
            }
        }
    }

    // 固定区顺序跟固定顺序走（不再跟列表排序走）：按住拖动
    // 换位改的就是这个顺序；已删 App 的残留键自然掉。
    private var pinnedItems: [PinnedStripItem] {
        // 3.8.295：按 pinKey 去重（保留第一项）——同一 App 可能同
        // 时以 pinKey 与 src: 键固定；src: 的已装项 295 后也解成
        // .installed，pinKey 与普通固定项相同，ForEach(id: pinKey)
        // 会重复 id（固定区出现两个相同图标、拖动错位）。
        var seenKeys = Set<String>()
        return pinnedStore.pinnedIds.compactMap { id in
            if id.hasPrefix("src:") {
                let bundleID = String(id.dropFirst(4))
                // 3.8.295：源固定项优先解析为已装 App——已装的走本
                // 地图标（清晰、不用联网），且 App 面板没有源解析
                // 器也能显示（之前只走 resolver，App 面板直接跳
                // 过，源 App 在 App 面板永远固定不上；源面板里远
                // 程图标下不来时也只剩灰块，看着像没固定上）。没
                // 装的才走源解析（点按走安装）。已装查找含隐藏
                // App（sortedApps 只有可见 App，隐藏的在另一份
                // sortedHiddenApps；源行 isInstalled 查的是两者之和）。
                if let app = (sortManager.sortedApps + sortManager.sortedHiddenApps).first(where: { $0.appInfo.bundleIdentifier() == bundleID }) {
                    return .installed(app)
                }
                guard let resolver = sourceAppResolver else { return nil }
                guard let app = resolver(bundleID) else { return nil }
                return .source(app)
            }
            if let app = sortManager.sortedApps.first(where: { CZFPinnedAppsStore.pinKey(for: $0) == id }) {
                return .installed(app)
            }
            return nil
        }.filter { item in seenKeys.insert(item.pinKey).inserted }
    }
    // 3.8.298：固定区图标发糊的根因——面板包在 GlassEffectContainer
    // 里，没挂 glassEffect 的子视图会被当成 backdrop 模糊掉；搜索框/
    // 列表行/运行条都有玻璃所以清晰。给固定图标也挂玻璃（圆角 12 与
    // clipShape 同形），图标本身保持清晰。
    // 3.8.300：不用 .modifier { content in }——298/299 两版都栽在它
    // 上面：pinnedIcon 返的是 @ViewBuilder 的 some View，链上
    // .frame/.clipShape 后 Self 是包着不透明类型的 ModifiedContent，
    // 自定义 modifier 扩展推不出闭包参数 content 的类型（四条红字
    // 两版一模一样，else 改透明底也没救，根因不在 else）。改成普通
    // @ViewBuilder 泛型函数，参数类型由实参显式推断，不靠闭包推断。
    @ViewBuilder
    private func pinnedIconGlass<Content: View>(_ content: Content) -> some View {
        if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
            content.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            content
        }
    }

    // 3.8.291：固定区图标——已装走 RunningAppIcon，源固定项
    // 走 iconURL 的 AsyncImage（与源行同款写法）。
    @ViewBuilder
    private func pinnedIcon(for item: PinnedStripItem) -> some View {
        switch item {
        case .installed(let app):
            RunningAppIcon(appInfo: app.appInfo)
        case .source(let app):
            AsyncImage(url: app.iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.25)
                }
            }
        }
    }
    @State private var draggedPinKey: String?

    var body: some View {
        // 直接贴面板底色排版，不再套一层灰卡（卡里套卡是用户
        // 点名"太丑"的主因）；图标 40pt / 圆角 12（用户定小点），
        // 运行区 46pt、列表行 52pt，左边缘对齐即可
        // 标题行已去掉（用户 2026-11-03 令去最顶部图钉与 ✕）：
        // 面板改由固定栏往下滑动隐藏，关面板走遮罩点按与下滑。
        VStack(alignment: .leading, spacing: 8) {
            if pinnedItems.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        // id 跟固定键走（不用下标，也不用实例本身）：
                        // 换位时 SwiftUI 按固定键身份做移动画，不会
                        // 把图标内容错位互换；源 App 每次刷新换 UUID，
                        // 按实例判等会抖，只能认键。
                        ForEach(Array(pinnedItems.enumerated()), id: \.element.pinKey) { pair in
                            let index = pair.offset
                            let item = pair.element
                            // 固定区只留图标、不要名字（用户定）：名字
                            // 字号小又挤，图标本身已够认；点按仍打开。
                            // 按住拖动换位（用户 2026-11-03 定）：iOS
                            // 的 onDrag 本来就要按住才起拖，与点按不
                            // 冲突；拖过目标即换位，松手即定。
                            pinnedIconGlass(
                                pinnedIcon(for: item)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            )
                                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    switch item {
                                    case .installed(let app):
                                        onLaunch(app)
                                    case .source(let app):
                                        // 3.8.291：源固定项点按 = 直接安装
                                        //（走源面板 installFromPanel 逻辑）。
                                        onInstallSourceApp?(app)
                                    }
                                }
                                .onDrag {
                                    draggedPinKey = item.pinKey
                                    return NSItemProvider(object: item.pinKey as NSString)
                                }
                                .onDrop(of: [.text], delegate: CZFPinnedReorderDelegate(targetIndex: index, store: pinnedStore, draggedKey: $draggedPinKey))
                        }
                    }
                    // 图标列对齐：固定区图标左边缘与运行条、列表行
                    // 图标列同线（外 16 + 内 10 = 26），标题行不动
                    .padding(.leading, 10)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 2)
        // 旧版按包名存的固定项迁移：面板打开时跑一次（模型到了
        // 才跑，模型没到不记完成、下次打开再跑；跑过一次就不再跑）。
        // 任务绑模型数：模型表从空变有也触发，不会卡在空表上。
        .task(id: sortManager.sortedApps.count) {
            pinnedStore.migrateLegacyPins(models: sortManager.sortedApps)
        }
    }
}

@available(iOS 16.0, *)
struct AllAppsListView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.czfPanelClose) private var czfPanelClose
    @EnvironmentObject var dockManager: MultitaskDockManager
    @ObservedObject private var sharedModel = DataManager.shared.model

    // 关闭面板：覆盖层（手势弹出）走注入的关闭动作；sheet（点蓝图标）走 dismiss
    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }
    @ObservedObject var sortManager = LCAppSortManager.shared

    // 面板启动失败提示：原来三条启动路全是 try? 吞错，面板又
    // 已关掉，失败时只剩“点了没反应”。手势覆盖层常驻窗口
    // （只改可见性不销毁），这个 @State alert 在覆盖层路能
    // 正常弹出；蓝图标 sheet 路 dismiss 后视图销毁，本地 alert
    // 弹不出——所以 sheet 路把错误经 onLaunchError 回传给
    // 弹出 sheet 的宿主视图弹（宿主不传回调时仍走本地 alert，
    // 手势路行为一字不动）。JIT 取消不抛错，不会误弹。
    @State private var launchError: String?

    // sheet 路启动失败回传通道（宿主弹 alert 用）：覆盖层路
    // 不传，仍走上面本地 launchError；只在 Task 报错时调一次。
    var onLaunchError: ((String) -> Void)? = nil

    private func reportLaunchError(_ message: String) {
        if let onLaunchError {
            onLaunchError(message)
        } else {
            launchError = message
        }
    }

    // 面板搜索：不用 .searchable（原来绑常量空串根本不筛选，
    // iOS 26 还把它渲染成悬浮条压住最后一行才被拆掉），改用
    // 普通 TextField 按名字/Bundle ID 过滤。
    @State private var searchText = ""

    private var filteredPanelApps: [LCAppModel] {
        if searchText.isEmpty { return sortManager.sortedApps }
        return sortManager.sortedApps.filter { app in
            app.appInfo.displayName().localizedCaseInsensitiveContains(searchText) ||
            (app.appInfo.bundleIdentifier() ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    // 3.8.284：已隐藏 App 也按同款搜索筛（与上面同一谓词）
    private var filteredHiddenApps: [LCAppModel] {
        let hidden = sharedModel.hiddenApps
        if searchText.isEmpty { return hidden }
        return hidden.filter { app in
            app.appInfo.displayName().localizedCaseInsensitiveContains(searchText) ||
            (app.appInfo.bundleIdentifier() ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // 3.8.304：滚动列表移出 GlassEffectContainer——301 把行上玻璃
        // 去掉治好了滑动盖头，但容器里没玻璃的子视图会被当成 backdrop
        // 模糊掉，302 的行全糊了（用户 2026-11-06 13:47 截图）。玻璃只
        // 给固定不动的铬（固定区/运行条/搜索框/面板底），滚动列表走实色、
        // 在容器外面，既不糊也不盖头。固定铬仍共用一个容器（一个 backdrop
        // pass，滚动不掉帧）；容器本身 iOS 26 才有，放 #available 里。
        VStack(spacing: 0) {
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                GlassEffectContainer(spacing: 8) {
                    appPanelHeader
                }
            } else {
                appPanelHeader
            }
            appPanelList
        }
        .background {
            // 3.8.292：容器玻璃背景层（与源面板同款）——玻璃
            // 不挂在内容 VStack 上（VStack 高度受底部安全区
            // 限制，底部约 40pt 铺不到，形成接缝线 + 两个底
            // 角没铺满）；背景层 + ignoresSafeArea 铺满宿主
            // 全高，内容不动。非玻璃分支同样铺满。
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                    .fill(.clear)
                    .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                    .ignoresSafeArea()
            } else {
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()
            }
        }
        // 启动失败提示（源面板同款写法）：面板已关、启动在后台
        // Task 里抛错时，把原因弹出来，不再“点了没反应”。
        .alert("提示", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("好") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
    }

    @ViewBuilder
    private var appPanelHeader: some View {
        // 不用 NavigationView：空标题的导航栏白占一条高度，面板
        // 本来就只有半屏多；原来挂的 .searchable 绑的是常量空串
        // （根本不筛选），iOS 26 还把它渲染成悬浮条压在面板底部，
        // 遮住最后一行（用户真机点名"一拉出来都遮挡住了"）。改成
        // 关闭钮并进固定区标题行：独立顶栏又是一层，顶部
        // 顶栏+固定+运行三层叠着（用户点名），省下的高度
        // 全留给列表
        VStack(spacing: 0) {
            // 顶部固定区（用户定）：不要"App"标题，换成可固定
            // 的 App 小图标横排（长按下面列表行固定/取消），
            // 固定区不随列表滚动
            PinnedAppsStripView(onLaunch: { app in launchApp(app) })
            // 状态栏条固定在顶部，不随列表滚动（原来在
            // ScrollView 里，往下翻卡片后收起/最小化/
            // 关闭全部就没了，得翻回顶部）
            RunningAppsStripView { closePanel() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            // 搜索框：固定在运行条下方，不随列表滚动。
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索", text: $searchText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier { content in
                // 3.8.292：搜索框玻璃（与源面板搜索框同款）；
                // 非玻璃系统走原来浅灰底 + 圆角。
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 10))
                } else {
                    content.background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var appPanelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filteredPanelApps, id: \.self) { app in
                        AppCardRow(app: app, dockManager: dockManager, onLaunch: {
                            launchApp(app)
                        }, onMinimizeOpen: {
                            minimizeOpenApp(app)
                        }, onSmallWindowOpen: {
                            smallWindowOpenApp(app)
                        })
                    }
                    // 已隐藏 App（3.8.284）：面板列表只走 sortedApps，
                    // hiddenApps 从没进来过，面板里永远看不到已隐藏的
                    // App。照主列表的做法：刷脸通过后直接显示（不带标
                    // 题），没通过只留一行高空白，长按空白弹人脸识别。
                    if !sharedModel.hiddenApps.isEmpty {
                        if sharedModel.isHiddenAppUnlocked {
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                AppCardRow(app: app, dockManager: dockManager, onLaunch: {
                                    launchApp(app)
                                }, onMinimizeOpen: {
                                    minimizeOpenApp(app)
                                }, onSmallWindowOpen: {
                                    smallWindowOpenApp(app)
                                })
                            }
                        } else {
                            Color.clear
                                .frame(height: 72)
                                .contentShape(Rectangle())
                                .onLongPressGesture {
                                    Task {
                                        do {
                                            _ = try await LCUtils.authenticateUser()
                                        } catch {
                                            launchError = error.localizedDescription
                                        }
                                    }
                                }
                        }
                    }
                }
                // 列表外边距显式写死 16：与固定区、运行条外边距
                // 同线；顶部不留白，运行条底 10 就是段间距
                .padding([.horizontal, .bottom], 16)
                .id("czfAppPanelTop")
            }
            .onChange(of: dockManager.czfAppPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置），搜索也一并清空。
                proxy.scrollTo("czfAppPanelTop", anchor: .top)
                searchText = ""
            }
        }
    }
    
    private func launchApp(_ app: LCAppModel) {
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == app.appInfo.dataUUID }) {
            // 窗口必须属于本条目：同包名别的条目若共用容器，
            // 按 dataUUID 找会把别人的窗口顶回来；归属对不上
            // 就不顶，走下面 URL 启动，runApp 里会拆共享容器。
            // runningApp 存在却无法证明归属（appInfo 缺失或路径
            // 为空）时同样视为未知，一律不顶；宁可多起一个窗口，
            // 不顶错别人的。
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                // 面板带回也拉满（卡片 3.8.238 同款语义，启动=
                // 大窗口）：带回成功且窗口未最大化时拉满；带回
                // 失败照原样关面板返回，不改落空路径；新开路
                // 在 3.8.240 已拉满，这里不动。
                if brought, let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController, !vc.isMaximized {
                    vc.maximizeWindow()
                }
                closePanel()
                return
            }
        }
        // 跳错修复：非运行实例不再走只带包名的 URL（那边按包名
        // 取首个模型，点第 2 个实例必开第 1 个），改走模型直启，
        // 与 smallWindowOpenApp 同款；上面运行中实例的顶回
        // 前台路径一字不动。
        closePanel()
        Task {
            do {
                try await app.runApp(containerFolderName: app.appInfo.dataUUID)
                // 新开路拉满（3.8.240）：面板启动同款，起完等窗进
                // dock 再拉满一次，不管上次关时大小；在跑的顶回
                // 前台那条路（上面）不动，不改面板点按聚焦行为。
                await MainActor.run {
                    self.pollAndMaximizeFreshWindow(app: app)
                }
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
    }

    // 启动新开路拉满（3.8.240，面板版）：与卡片同款逻辑，
    // 0.1 秒×60 次轮询等新窗进 dock，归属按路径验。
    private func pollAndMaximizeFreshWindow(app: LCAppModel) {
        let expectedPath = app.appInfo.relativeBundlePath
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            attempts += 1
            let uuid = app.uiSelectedContainer?.folderName ?? app.appInfo.dataUUID
            guard let uuid = uuid,
                  let entry = self.dockManager.apps.first(where: { $0.appUUID == uuid }) else {
                if attempts >= 60 {
                    timer.invalidate()
                }
                return
            }
            let owned: Bool
            if let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                owned = runningPath == expectedPath
            } else {
                owned = false
            }
            if !owned {
                timer.invalidate()
                return
            }
            guard let vc = entry.view?._viewDelegate() as? DecoratedAppSceneViewController else {
                if attempts >= 20 {
                    timer.invalidate()
                }
                return
            }
            if !vc.isMaximized {
                vc.maximizeWindow()
            }
            if vc.isMaximized || attempts >= 20 {
                timer.invalidate()
            }
        }
    }
    
    private func minimizeOpenApp(_ app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        // 如果已在运行，直接最小化它的窗口；归属不明按启动/
        // 小窗口路同款视为别的条目（?? true），不再直接最小化。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
            let belongsToOther = runningApp.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 != app.appInfo.relativeBundlePath } ?? true
            if !belongsToOther {
                dockManager.minimizeWindow(uuid: runningApp.appUUID)
                closePanel()
                return
            }
        }        // 未运行：先启动，延迟后最小化窗口
        closePanel()
        // 跳错修复：未运行实例不再走只带包名的 URL（按包名取
        // 首个模型，点的实例若非首个会被开错），改走模型直启；
        // 下面按 dataUUID 轮询最小化的逻辑一字不动；上面运行
        // 分支的归属守卫一字不动。
        Task {
            do {
                try await app.runApp(containerFolderName: dataUUID)
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
        // 主线程轮询等待窗口出现，找到后最小化；只认归属对得上
        // 的条目，别人的窗口占着 uuid 时直接停表、不碰它（自己
        // 的新窗若拆容器会换 uuid，等这个 uuid 也等不来）。
        // 轮询到期给提示：以前到期只停表、界面上什么都没发生，
        // 用户以为点了没反应；到期分不清失败还是拆容器换号，
        // 文案只说没等到窗口、不定性为启动失败。
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            attempts += 1
            if let entry = self.dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
                let owned = entry.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 == app.appInfo.relativeBundlePath } ?? false
                if owned {
                    self.dockManager.minimizeWindow(uuid: dataUUID)
                }
                timer.invalidate()
            } else if attempts >= 60 {
                timer.invalidate()
                self.reportLaunchError("最小化超时：6 秒内没等到「\(app.appInfo.displayName() ?? "App")」的窗口，请确认 App 已打开后重试")
            }
        }
    }

    // 直接以小窗口（多任务）打开：窗口若被设置成最大化打开，还原成小窗口尺寸
    private func smallWindowOpenApp(_ app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        // 已在运行：把它的窗口带到前面，并还原为小窗口
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
            // runningApp 存在却无法证明归属（appInfo 缺失或路径
            // 为空）时视为未知，一律不顶窗口，交给 runApp 起新
            // 窗口；宁可多起一个窗口，不顶错别人的。
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != app.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                if brought {
                    unmaximizeWindow(uuid: dataUUID)
                    closePanel()
                    return
                }
                // 带回失败：条目还在且不是本次 C4 清掉的（窗口
                // 不在任何窗口里等）→ 保持旧行为，不重复起新窗；
                // 本次 C4 清掉了死窗，或 prune 同步剪掉了无窗残
                // 留（条目已不在）→ 落到下面 runApp 起新窗（即
                // 重启入口）。注意不能只查条目在不在：C4 的
                // removeRunningApp 是异步的，刚调完时条目还在。
                let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == dataUUID
                let entryGone = !dockManager.apps.contains(where: { $0.appUUID == dataUUID })
                if !cleanedByC4 && !entryGone {
                    unmaximizeWindow(uuid: dataUUID)
                    closePanel()
                    return
                }
            }
        }
        closePanel()
        // C6 回调驱动：先注册、再启动——窗口出现（dock 条目
        // 追加）才还原为小窗，不再 0.3 秒×30 次轮询、9 秒过期；
        // 启动慢（签名/VPN/JIT）时窗出来仍能还原。30 秒未出现
        // 则放弃等，不留野观察者；还原前仍留 0.35 秒让窗落稳。
        // 还原前按路径复验归属（L5）：同 uuid 条目已存在时回调
        // 立即触发、不验归属——占着 uuid 的若是别人的窗口，复验
        // 拦住，别把别人的窗口还原成小窗。
        let expectedPath = app.appInfo.relativeBundlePath
        dockManager.czfOnWindowAppeared(uuid: dataUUID, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.unmaximizeWindowIfOwned(uuid: dataUUID, expectedPath: expectedPath)
            }
        }
        Task {
            do {
                try await app.runApp(multitask: true, containerFolderName: dataUUID)
            } catch {
                await MainActor.run { reportLaunchError(error.localizedDescription) }
            }
        }
    }

    private func unmaximizeWindow(uuid: String) {
        guard let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
    }

    // 小窗口回落路专用（3.8.239）：见卡片同款 helper 注释。
    private func unmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        unmaximizeWindow(uuid: uuid)
    }
}

// MARK: - Sources Panel View（左边缘往外弹调出，与 App 面板对称；2026-10-23 对调）
// 数据复用源页面的 AltStoreSourcesViewModel（进面板自动加载+刷新，
// 每次调出计数变化再刷一次）；行卡片按源页 LCSourceAppBanner 的状态
// 逻辑简化（复制/下载/安装/打开/更新/已安装），安装走与源页完全相同
// 的通道：IPA 发 InstallAppNotification 给 App 列表执行，dylib 直装
// 插件目录并签名。
@available(iOS 16.0, *)
struct SourcesPanelView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.czfPanelClose) private var czfPanelClose
    @EnvironmentObject var dockManager: MultitaskDockManager
    @StateObject private var viewModel = AltStoreSourcesViewModel()
    @State private var errorMessage: String?
    // 3.8.308：VPN 开关状态（CZFVPNManager 不是 ObservableObject，
    // 读 isRunning 落 @State，打开面板时刷新一次、切完再刷新一次）
    @State private var vpnCoreRunning: Bool = false
    // 3.8.310：添加自定义快捷方式的选单开关（点“+”弹选单，
    // 选设置页或 App 的某个设置加进快捷行）。
    @State private var showCustomSettingsPicker: Bool = false
    // 3.8.310：自定义快捷方式列表（可添加多个单独图标，存在
    // UserDefaults 数组里；@State 持有当前快照，增删后刷新）。
    @State private var customShortcuts: [String] = []
    // 3.8.316：快捷行拖动调序——正在拖的快捷条目（同固定区
    // draggedPinKey 的路，拖过目标即换位、松手即定）。
    @State private var draggedShortcutKey: String?
    // 3.8.311：App 设置快捷方式的开关状态快照（key 是完整条目串，
    // 值是开/关；打开面板、增删、点按切换后刷新，角标颜色用它）。
    @State private var settingStates: [String: Bool] = [:]
    // 3.8.311：多选项类快捷方式要打开的 App 设置页（sheet 用）。
    @State private var settingsApp: LCAppModel?
    @State private var showAppSettings: Bool = false
    // 3.8.346：备份/恢复直进的单独页——源面板点备份/恢复四路
    // （.restore/.selectbackup/.backupall/.schedulebackup）不再
    // 走 deepLink + 设置页 sheet + 数据管理页的层层套（内层
    // fullScreenCover 在外层 sheet 动画里被 SwiftUI 丢掉、344
    // fallback 1.2 秒放弃、czfDismissIfDirectEntryDone 1.5 秒
    // dismiss 整页回设置页：用户到不了弹框按钮，还看到设置页）。
    // 改从源面板直接 fullScreenCover 整个 LCDataManagementView
    // （initialSheet 对应值），零状态搬迁（82 个 @State 都在
    // LCDataManagementView 自己身上，只依赖 sharedModel 与
    // sceneDelegate 两个 @EnvironmentObject，系统自动注入）。
    // 宿主是独立 UIHostingController（其 view 是目标窗口的子
    // 视图，见 ensureSourcesOverlay），fullScreenCover 从它
    // present，盖满目标窗口；closePanel 只隐藏宿主 view（不摘
    // 除、不释放），cover 不受影响。czfDismissIfDirectEntryDone
    // 里的 dismiss() 在 cover 里同样关掉 cover，回源面板。
    @State private var czfDirectDataPage: CZFSettingsPage? = nil
    // 3.8.309：VPN 节点菜单状态（与 App 页盾牌同款：长按选节点
    // 挂延迟，点按开关核心；测速结果只存本面板，不动 App 页）。
    @State private var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    @State private var vpnPinging: Bool = false

    // 3.8.309：VPN 开关（与 App 页 toggleVPNCore 同款：先记手动
    // 切换、再起/停、再刷新状态）。
    private func togglePanelVPNCore() {
        CZFVPNManager.shared.noteManualCoreToggle(started: !vpnCoreRunning)
        if vpnCoreRunning {
            CZFVPNManager.shared.stop()
        } else {
            _ = CZFVPNManager.shared.start()
        }
        vpnCoreRunning = CZFVPNManager.shared.isRunning
    }

    // 3.8.309：节点行字（与 App 页 vpnNodeMenuLabel 同款：当前
    // 节点打 ✓，测过延迟挂毫秒数，失败挂“失败”）。
    private func panelVPNNodeMenuLabel(idx: Int, link: String) -> String {
        let name = CZFVPNManager.nodeDisplay(for: link).name
        var suffix = ""
        if let r = vpnPingResults[idx] {
            suffix = r.success ? " · \(r.delay)ms" : " · 失败"
        }
        let mark = idx == CZFVPNManager.shared.activeNodeIndex ? "✓ " : ""
        return mark + name + suffix
    }

    // 3.8.309：测延迟（与 App 页 toolbarPingNodes 同款：先停核心
    // 再测、测完重启原来那条；被拒不覆写旧结果；测完自动切最快）。
    private func panelToolbarPingNodes() {
        guard !vpnPinging else { return }
        let links = CZFVPNManager.shared.nodeLinks
        guard !links.isEmpty else { return }
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        CZFVPNManager.shared.pingAllNodes { results, rejected in
            self.vpnPinging = false
            var bestIndex: Int? = nil
            if !rejected {
                var stored: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                for (idx, r) in results.enumerated() { stored[idx] = r }
                self.vpnPingResults = stored
                if let best = results.enumerated().filter({ $0.element.success }).min(by: { $0.element.delay < $1.element.delay }) {
                    bestIndex = best.offset
                }
            }
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            if let best = bestIndex, best != CZFVPNManager.shared.activeNodeIndex, best < CZFVPNManager.shared.nodeLinks.count {
                CZFVPNManager.shared.setActiveNode(at: best)
            }
        }
    }

    // 3.8.309：切到最快（与 App 页 switchToFastestNode 同款：有
    // 本轮测速结果直接切，没有就先测再切；下标先判界防越界）。
    private func panelSwitchToFastestNode() {
        let links = CZFVPNManager.shared.nodeLinks
        if let best = vpnPingResults.filter({ $0.value.success && $0.key < links.count }).min(by: { $0.value.delay < $1.value.delay }) {
            CZFVPNManager.shared.setActiveNode(at: best.key)
            return
        }
        panelToolbarPingNodes()
    }

    // 3.8.309：菜单顶上当前节点名和延迟（与 App 页同款；没测过
    // 显示“未测速”，没节点显示“暂无节点”）。
    private var panelVPNCurrentNodeLabel: String {
        let links = CZFVPNManager.shared.nodeLinks
        guard !links.isEmpty else { return "暂无节点" }
        let idx = CZFVPNManager.shared.activeNodeIndex
        guard idx < links.count else { return "暂无节点" }
        let name = CZFVPNManager.nodeDisplay(for: links[idx]).name
        if let r = vpnPingResults[idx] {
            return r.success ? "当前节点：\(name) · \(r.delay)ms" : "当前节点：\(name) · 失败"
        }
        return "当前节点：\(name) · 未测速"
    }

    // 3.8.309：节点子菜单（与 App 页 vpnNodeSubmenu 同款）。
    @ViewBuilder
    private var panelVPNNodeSubmenu: some View {
        Menu("选择节点") {
            if CZFVPNManager.shared.nodeLinks.isEmpty {
                Button("暂无节点") {}
                    .disabled(true)
            } else {
                ForEach(Array(CZFVPNManager.shared.nodeLinks.enumerated()), id: \.offset) { idx, link in
                    Button {
                        CZFVPNManager.shared.setActiveNode(at: idx)
                    } label: {
                        Text(panelVPNNodeMenuLabel(idx: idx, link: link))
                    }
                }
            }
        }
    }

    // 3.8.309：VPN 盾牌菜单（与 App 页 vpnShieldMenu 同款：点按
    // 开关核心，长按弹菜单；图标是小圆底盾牌，绿=开、灰=关）。
    @ViewBuilder
    private var panelVPNMenu: some View {
        Menu {
            Button(panelVPNCurrentNodeLabel) {}
                .disabled(true)
            Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                togglePanelVPNCore()
            }
            Button(vpnPinging ? "测速中…" : "测延迟") {
                panelToolbarPingNodes()
            }
            .disabled(vpnPinging || CZFVPNManager.shared.nodeLinks.isEmpty)
            panelVPNNodeSubmenu
            Button("切到最快") {
                panelSwitchToFastestNode()
            }
            .disabled(CZFVPNManager.shared.nodeLinks.isEmpty)
            Button("前往 VPN 设置") {
                closePanel()
                DataManager.shared.model.selectedTab = .settings
            }
        } label: {
            // 3.8.315：盾牌常驻实心——之前关时用空心 shield，
            // 细线条在灰圆底上显得比旁边实心蓝图标小一圈，
            // 用户 19:40 红条指出跟固定图标对不齐；改成常驻
            // shield.fill，开关只靠颜色区分（绿=开、灰=关），
            // 跟旁边实心图标同等视觉分量。
            Image(systemName: "shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(vpnCoreRunning ? .green : .secondary)
                .frame(width: 40, height: 40)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Circle())
        } primaryAction: {
            togglePanelVPNCore()
        }
    }

    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }

    // 3.8.308：直开某设置页——先关面板、切到设置页签、
    // 再把 deepLink 交给设置页（LCSettingsView.handleURL
    // 按 host 弹对应页面；host 不认就只停在设置页）。
    // 3.8.346：备份/恢复四路（.restore/.selectbackup/
    // .backupall/.schedulebackup）不再走 deepLink——改直
    // 接 fullScreenCover 单独页（见 czfDirectDataPage 注释），
    // 不进设置页 sheet、不套数据管理页；其余路由一字不动。
    private func openSettingsPage(_ page: String) {
        if let czfPage = CZFSettingsPage(rawValue: page),
           czfPage == .restore || czfPage == .selectbackup || czfPage == .backupall || czfPage == .schedulebackup {
            closePanel()
            czfDirectDataPage = czfPage
            return
        }
        closePanel()
        DataManager.shared.model.selectedTab = .settings
        DataManager.shared.model.deepLink = URL(string: "livecontainer://\(page)")
    }

    // 3.8.308：源面板搜索已去掉（用户亲令），列表不再按名字/
    // 包名筛——整节原样显示；matchedApps 只剩一个透传壳，
    // 行里还调它，留着不动结构。
    private func matchedApps(for source: AltStoreSource) -> [AltStoreSourceApp] {
        return source.apps
    }

    // 3.8.284：源面板固定区图标点按启动（与源行“打开”同款：
    // 先关面板再跑 App；App 面板 launchApp 的“已运行顶回前台”
    // 那段不搬，最小版先用关面板 + runApp）
    private func launchPinnedApp(_ app: LCAppModel) {
        closePanel()
        Task { try? await app.runApp() }
    }

    // 3.8.310：按 pinKey（包名_dataUUID）找已装 App（自定义
    // 快捷方式里的 App 设置用它解析；找不到就当这条快捷方式
    // 失效、不渲染）。
    private func app(forPinKey pinKey: String) -> LCAppModel? {
        (LCAppSortManager.shared.sortedApps + LCAppSortManager.shared.sortedHiddenApps)
            .first { CZFPinnedAppsStore.pinKey(for: $0) == pinKey }
    }

    // 3.8.311：App 设置快捷方式——开关类点按直接切换，
    // 多选项类点按打开该 App 的设置页（用户 17:34 亲定）。

    /// 读某个开关类快捷方式的当前状态（多选项类 / 解析失败返回 nil）。
    private func currentSettingState(item: String) -> Bool? {
        guard let (pinKey, key) = CZFPanelCustomShortcuts.settingPinKeyAndKey(from: item),
              let app = app(forPinKey: pinKey),
              let setting = CZFPanelAppSetting(rawValue: key),
              setting.isToggle else { return nil }
        switch setting {
        case .schedMin: return isSchedMinOn(for: app)
        case .fixNotify: return app.uiFixLocalNotification
        case .vpn: return CZFVPNManager.isEnabled(for: app.appInfo)
        case .keepAlive: return isKeepAliveOn(for: app)
        case .jit: return app.uiIsJITNeeded
        case .fixPicker: return app.uiFixFilePickerNew
        case .useLCBundleId: return app.uiUseLCBundleId
        case .hideLiveContainer: return app.uiHideLiveContainer
        case .classicMode: return app.uiClassicMode
        case .spoofSDK: return app.uiSpoofSDKVersion
        case .symlinkInbox: return app.uiDoSymlinkInbox
        case .dontInjectTweak: return app.uiDontInjectTweakLoader
        case .openSettings: return nil
        }
    }

    /// 刷新全部开关状态快照（打开面板、增删、点按切换后调）。
    private func refreshSettingStates() {
        var states: [String: Bool] = [:]
        for item in customShortcuts {
            if let state = currentSettingState(item: item) {
                states[item] = state
            }
        }
        settingStates = states
    }

    /// 开关角标色：开 = 绿，关 = 灰；多选项类恒蓝。
    private func settingBadgeColor(for item: String, setting: CZFPanelAppSetting) -> Color {
        guard setting.isToggle else { return .blue }
        return (settingStates[item] ?? false) ? .green : .gray
    }

    /// 点按开关类快捷方式：直接切换该设置（不进设置页）。
    private func toggleSetting(item: String) {
        guard let (pinKey, key) = CZFPanelCustomShortcuts.settingPinKeyAndKey(from: item),
              let app = app(forPinKey: pinKey),
              let setting = CZFPanelAppSetting(rawValue: key),
              setting.isToggle else { return }
        switch setting {
        case .schedMin: toggleSchedMin(for: app)
        case .fixNotify: app.uiFixLocalNotification.toggle()
        case .vpn: CZFVPNManager.setEnabled(!CZFVPNManager.isEnabled(for: app.appInfo), for: app.appInfo)
        case .keepAlive: toggleKeepAlive(for: app)
        case .jit: app.uiIsJITNeeded.toggle()
        case .fixPicker: app.uiFixFilePickerNew.toggle()
        case .useLCBundleId: app.uiUseLCBundleId.toggle()
        case .hideLiveContainer: app.uiHideLiveContainer.toggle()
        case .classicMode: app.uiClassicMode.toggle()
        case .spoofSDK: app.uiSpoofSDKVersion.toggle()
        case .symlinkInbox: app.uiDoSymlinkInbox.toggle()
        case .dontInjectTweak: app.uiDontInjectTweakLoader.toggle()
        case .openSettings: break
        }
        refreshSettingStates()
    }

    // 定时最小化打开：同款 LCAppSettingsView.saveSchedMinSettings
    //（键 CZFSchedMinEnabled-<bid> / CZFSchedMinMinutes-<bid>，
    // 默认 8:00；切开关不重置已设时间；开定时要踢一下轮询表，
    // 否则之前停掉的表不会自己恢复）。
    private func isSchedMinOn(for app: LCAppModel) -> Bool {
        guard let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: "CZFSchedMinEnabled-\(bid)")
    }

    private func toggleSchedMin(for app: LCAppModel) {
        guard let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty else { return }
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: "CZFSchedMinEnabled-\(bid)")
        defaults.set(newValue, forKey: "CZFSchedMinEnabled-\(bid)")
        if defaults.object(forKey: "CZFSchedMinMinutes-\(bid)") == nil {
            defaults.set(8 * 60, forKey: "CZFSchedMinMinutes-\(bid)")
        }
        defaults.removeObject(forKey: "CZFSchedMinLastDate-\(bid)")
        if newValue, #available(iOS 16.0, *) {
            MultitaskDockManager.shared.czfKickSchedMinTimer()
        }
    }

    // 每 App 保活：同款 LCAppSettingsView.setKeepAlive
    //（白名单文件 CZFKeepAliveApps.txt 在两夹；不存在 = 全保）。
    private func keepAliveListURLs() -> [URL] {
        [LCPath.tweakPath, LCPath.lcGroupTweakPath].map { $0.appendingPathComponent("CZFKeepAliveApps.txt") }
    }

    private func readKeepAliveList() -> [String]? {
        for url in keepAliveListURLs() {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        return nil
    }

    private func writeKeepAliveList(_ list: [String]) throws {
        let content = list.isEmpty ? "" : list.joined(separator: "\n") + "\n"
        let fm = FileManager()
        for url in keepAliveListURLs() {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func isKeepAliveOn(for app: LCAppModel) -> Bool {
        guard let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty else { return true }
        if let list = readKeepAliveList() {
            return list.contains(bid)
        }
        return true
    }

    private func toggleKeepAlive(for app: LCAppModel) {
        guard let bid = app.appInfo.bundleIdentifier(), !bid.isEmpty else { return }
        let on = !isKeepAliveOn(for: app)
        do {
            if on {
                if var list = readKeepAliveList() {
                    if !list.contains(bid) {
                        list.append(bid)
                        try writeKeepAliveList(list)
                    }
                }
                // 文件不存在 = 本来就全保，不用写
            } else {
                if var list = readKeepAliveList() {
                    list.removeAll { $0 == bid }
                    try writeKeepAliveList(list)
                } else {
                    // 首次关：用全部 App 名单种子，只去掉这个 App
                    let all = (LCAppSortManager.shared.sortedApps + LCAppSortManager.shared.sortedHiddenApps).compactMap { $0.appInfo.bundleIdentifier() }.filter { !$0.isEmpty && $0 != bid }
                    guard !all.isEmpty else { return }
                    try writeKeepAliveList(all)
                }
            }
            CZFHostKeepAlive.shared.refresh()
        } catch {
            // 写失败就当没切（刷新后角标仍显旧值）
        }
    }

    var body: some View {
        // 3.8.304：滚动列表移出 GlassEffectContainer（与 App 面板同款
        // 原因：301 去行上玻璃治好滑动盖头，但容器里没玻璃的子视图会被
        // 当成 backdrop 模糊掉，302 的行全糊了，用户 2026-11-06 13:47
        // 截图）。玻璃只给固定不动的铬，滚动列表走实色、在容器外面。
        VStack(spacing: 0) {
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                GlassEffectContainer(spacing: 8) {
                    sourcesPanelHeader
                }
            } else {
                sourcesPanelHeader
            }
            sourcesPanelList
        }
        .background {
            // 3.8.292：容器玻璃改成背景层——玻璃不再挂在内容
            // VStack 上（VStack 高度受底部安全区限制，底部约
            // 40pt 铺不到，形成接缝线 + 两个底角没铺满）；背景
            // 层 + ignoresSafeArea 铺满宿主全高，内容不动。
            // 非玻璃分支同样铺满（原来只铺 VStack，底部安全
            // 区同样会露底）。形状、圆角与原来一字不动。
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                    .fill(.clear)
                    .glassEffect(.regular, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
                    .ignoresSafeArea()
            } else {
                Color(UIColor.systemBackground)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var sourcesPanelHeader: some View {
        // 3.8.288：源面板去顶栏（用户 2026-11-06 亲令去源名字
        // 和图标）：“源”标题 + ✕关闭 + 刷新全删。照 App 面板
        // 同款不用 NavigationView（空标题导航栏白占一条高度）；
        // 关面板走遮罩点按/下滑/收起钮，刷新走每次调出时
        // onChange 里的自动刷新（与 App 面板同款）。
        // 3.8.308：搜索框去掉（用户亲令）；运行条只在有打开
        // 的 App 时显示；搜索框的位置改成快捷开关行——VPN
        // 开关 + 数据管理 + 自定义设置（可配，直开某设置页）。
        VStack(spacing: 0) {
            // 3.8.284：源面板与 App 面板一致——顶部固定区（复用
            // PinnedAppsStripView，同一批固定 App），顺序与 App
            // 面板同款：固定区 → 运行条 → 快捷开关 → 列表
            // 3.8.291：源面板把源数据传进固定区——源固定项按
            // 包名在各源里找对应 App 解析，点按直接安装。
            PinnedAppsStripView(
                onLaunch: { app in launchPinnedApp(app) },
                emptyHint: "在 App 面板长按 App 可固定到这里",
                sourceAppResolver: { bundleIdentifier in
                    viewModel.sources.compactMap(\.source).flatMap(\.apps).first { $0.bundleIdentifier == bundleIdentifier }
                },
                onInstallSourceApp: { app in installFromPanel(app: app) }
            )
            // 运行条固定在顶部，不随列表滚动（与 App 面板一致）。
            // 3.8.341：去掉“没打开 App 就不显示”的条件——用户
            // 16:49 点名源面板也要收起/最小化/关闭全部：没运行
            // App 时三个按钮照样要能点（收起面板、最小化、关
            // 全部），不能因为没运行 App 就把整条藏掉。没运行
            // App 时 RunningAppsStripView 自己把三个按钮均分
            // 整行，不占多余地方；与 App 面板同款无条件显示。
            RunningAppsStripView { closePanel() }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            // 快捷图标行（固定在运行条下方、不随列表滚动）
            // 3.8.309：三个小图标，大小一样、间距平均；VPN 点按
            // 开关、长按选节点（与 App 页盾牌同款 Menu）。
            // 3.8.322 液体化繁为简：根上对齐——原来居中 Spacer +
            // offset(-4/-6/-8) 来回调，图标一多整行就溢出到固定区
            // 第一图标左边去（用户 02:34 定：不得超过第一个固定
            // App 位置、要对齐）。改成跟固定区同款结构：横滑
            // ScrollView + HStack + 内缩 10，外 16，首图标左缘
            // 恒在 26，与固定区第一图标同线；图标再多只往右滑，
            // 不再左溢；offset 删掉，不再调数字。间距 16→14，
            // 与固定区统一。里面按钮/菜单/拖动一字不动。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // VPN：点按开关核心，长按弹节点菜单
                    panelVPNMenu
                    // 3.8.315：用户 19:39 令——快捷行只留 VPN 默认，
                    // 数据管理固定图标去掉（数据管理仍在设置页里，
                    // 不再占快捷行一个位置）。
                    // 自定义快捷方式（3.8.311：用户要的不是加 App
                    // 快捷，而是把 APP 详情页里的设置加为快捷方式——
                    // 某个 App 的某个开关/设置。开关类点按直接切换
                    //（角标绿=开、灰=关），多选项类点按打开该 App
                    // 的设置页；长按可移除）。
                    ForEach(customShortcuts, id: \.self) { item in
                        if let raw = CZFPanelCustomShortcuts.pageRaw(from: item),
                           let page = CZFSettingsPage(rawValue: raw) {
                            Button {
                                openSettingsPage(page.rawValue)
                            } label: {
                                Image(systemName: page.icon)
                                    .font(.system(size: 22))
                                    .foregroundStyle(.blue)
                                    .frame(width: 40, height: 40)
                                    .background(Color(UIColor.secondarySystemBackground))
                                    .clipShape(Circle())
                            }
                            .contextMenu {
                                Button("移除此快捷方式", role: .destructive) {
                                    CZFPanelCustomShortcuts.remove(item)
                                    customShortcuts = CZFPanelCustomShortcuts.items
                                    refreshSettingStates()
                                }
                            }
                            // 3.8.316：按住拖动调序（同固定区拖动换位）。
                            .onDrag {
                                draggedShortcutKey = item
                                return NSItemProvider(object: item as NSString)
                            }
                            .onDrop(of: [.text], delegate: CZFCustomShortcutReorderDelegate(
                                targetIndex: customShortcuts.firstIndex(of: item) ?? 0,
                                items: $customShortcuts,
                                draggedKey: $draggedShortcutKey
                            ))
                        } else if let (pinKey, key) = CZFPanelCustomShortcuts.settingPinKeyAndKey(from: item),
                                  let app = app(forPinKey: pinKey),
                                  let setting = CZFPanelAppSetting(rawValue: key) {
                            Button {
                                if setting.isToggle {
                                    toggleSetting(item: item)
                                } else {
                                    settingsApp = app
                                    showAppSettings = true
                                }
                            } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    RunningAppIcon(appInfo: app.appInfo)
                                        .frame(width: 40, height: 40)
                                        .clipShape(Circle())
                                    // 3.8.314：角标必须完全落在 40 圆内——313 只去了
                                    // offset(2,2) 还不够：20 角标贴在右下角时，
                                    // 圆心离主圆圆心 14.1、半径 10，最远点 24.1
                                    // 仍探出主圆（半径 20）约 4pt，用户 19:37
                                    // 截图证实还挂在边上；改成内收 4pt 后最远点
                                    // 18.5，整颗角标收进圆内，跟旁边 40 圆图标齐。
                                    Circle()
                                        .fill(settingBadgeColor(for: item, setting: setting))
                                        .frame(width: 20, height: 20)
                                        .overlay(
                                            Image(systemName: setting.icon)
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.white)
                                        )
                                        .offset(x: -4, y: -4)
                                }
                            }
                            .contextMenu {
                                Button("移除此快捷方式", role: .destructive) {
                                    CZFPanelCustomShortcuts.remove(item)
                                    customShortcuts = CZFPanelCustomShortcuts.items
                                    refreshSettingStates()
                                }
                            }
                            // 3.8.316：按住拖动调序（同固定区拖动换位）。
                            .onDrag {
                                draggedShortcutKey = item
                                return NSItemProvider(object: item as NSString)
                            }
                            .onDrop(of: [.text], delegate: CZFCustomShortcutReorderDelegate(
                                targetIndex: customShortcuts.firstIndex(of: item) ?? 0,
                                items: $customShortcuts,
                                draggedKey: $draggedShortcutKey
                            ))
                        }
                    }
                    // 加号：添加一个自定义快捷方式（点开选页单）
                    Button {
                        showCustomSettingsPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22))
                            .foregroundStyle(.blue)
                            .frame(width: 40, height: 40)
                            .background(Color(UIColor.secondarySystemBackground))
                            .clipShape(Circle())
                    }
                }
                // 内缩 10：与固定区 HStack 的内缩同数，外 16 +
                // 内 10 = 首图标左缘 26，与固定区第一图标同线。
                .padding(.leading, 10)
            }
            // 上下间距 8/8（3.8.312 定：跟搜索框下沿同距，
            // 上下对称）；offset 已删，位置由布局本身保证。
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .onAppear {
                vpnCoreRunning = CZFVPNManager.shared.isRunning
                CZFPanelCustomShortcuts.migrateIfNeeded()
                customShortcuts = CZFPanelCustomShortcuts.items
                refreshSettingStates()
            }
            // 3.8.311：多选项类快捷方式打开的 App 设置页（sheet 挂
            // 在快捷行上，与选页单的 sheet 挂在不同视图，避免
            // 同一视图挂两个 sheet 冲突；设置页要 SharedModel，
            // 面板根视图已注入 DataManager.shared.model）。
            .sheet(isPresented: $showAppSettings) {
                if let app = settingsApp {
                    NavigationView {
                        LCAppSettingsView(model: app)
                            .navigationTitle(app.appInfo.displayName() ?? "")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("关闭") { showAppSettings = false }
                                }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showCustomSettingsPicker) {
            CZFPanelCustomSettingsPicker { item in
                CZFPanelCustomShortcuts.add(item)
                customShortcuts = CZFPanelCustomShortcuts.items
                showCustomSettingsPicker = false
                if let raw = CZFPanelCustomShortcuts.pageRaw(from: item) {
                    openSettingsPage(raw)
                }
                // 3.8.311：App 设置类只加图标，不马上执行——
                // 开关类马上切会把已开的切成关（翻转当前态），
                // 多选项类马上开页会跟选页单的 sheet 抢呈现；
                // 加完点图标再用，一眼看清。
                refreshSettingStates()
            }
        }
        // 3.8.346：备份/恢复单独页——直接 fullScreenCover 整个
        // LCDataManagementView(initialSheet:)，跳过设置页 sheet
        // （见 czfDirectDataPage 注释）。NavigationView 包一层
        // 才能放“关闭”按钮（LCSettingsView:309 的 sheet toolbar
        // 绕开后就没了）；点关闭清 @State 关 cover。标题用
        // CZFSettingsPage.title（恢复数据/选择备份/备份全部/
        // 定时备份）。LCDataManagementView 自己的 Form 内层
        // fullScreenCover（备份选页/恢复选页）照常挂在它身上。
        .fullScreenCover(item: $czfDirectDataPage) { page in
            NavigationView {
                page.destinationView
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { czfDirectDataPage = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var sourcesPanelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // 滚回顶部锚点（条子已挪到 ScrollView 外面，
                    // 这里留个 0 高锚点，调出面板仍滚回最顶部）
                    // 3.8.312：间距 16→10（与 App 面板列表同距；
                    // 快捷行下沿到第一个源名的距离 = 快捷行底距
                    // 8 + 这 10，跟着收紧）。
                    Color.clear.frame(height: 0).id("czfSourcesPanelTop")
                    if viewModel.sources.isEmpty {
                        Text("还没有添加源")
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    ForEach(viewModel.sources) { item in
                        if let source = item.source {
                            // 搜不到的节不渲染（源名命中则整节保留，见 matchedApps）
                            if !matchedApps(for: source).isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    // 3.8.342：源名标题去掉（用户 17:12 亲令，
                                    // “解剖自我 🅥”那行不要，App 直接列出来，
                                    // 照他发的截图那样）。
                                    ForEach(matchedApps(for: source)) { app in
                                        SourcePanelRow(app: app, onInstall: { installFromPanel(app: app) }, onDownload: { downloadFromPanel(app: app) }, onDownloadVersion: { version in downloadFromPanel(url: version.downloadURL) })
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        } else if item.isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(item.displayName)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                        } else if let err = item.error {
                            Text("\(item.displayName) 加载失败：\(err)")
                                .font(.footnote)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: dockManager.czfSourcesPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置）+ 刷新源数据 + 刷新 VPN
                // 开关状态（与 App 面板同款）
                proxy.scrollTo("czfSourcesPanelTop", anchor: .top)
                vpnCoreRunning = CZFVPNManager.shared.isRunning
                Task { await viewModel.refreshAllSources() }
            }
            .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // 与源页 LCSourcesView.install 一致，额外关掉面板让用户看安装进度
    @MainActor
    private func installFromPanel(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        if downloadURL.pathExtension.lowercased() == "dylib" {
            Task { await installTweakFromPanel(from: downloadURL, name: app.name) }
            return
        }
        DataManager.shared.model.selectedTab = .apps
        closePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
        }
    }

    // 与源页 LCSourcesView.installTweak 一致
    @MainActor
    private func installTweakFromPanel(from url: URL, name: String) async {
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let fm = FileManager.default
            let folderURL = LCPath.tweakPath.appendingPathComponent(name)
            if !fm.fileExists(atPath: folderURL.path) {
                try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)
            }
            let destURL = folderURL.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: tempURL, to: destURL)
            try await LCUtils.signTweaks(tweakFolderUrl: folderURL, force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // 与源页 LCSourcesView.download 一致：下载到文档目录后弹分享框
    @MainActor
    private func downloadFromPanel(app: AltStoreSourceApp) {
        guard let downloadURL = app.latestVersion?.downloadURL else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        downloadFromPanel(url: downloadURL)
    }

    // 3.8.291：历史版本下载——指定任意版本 URL 下载（不只 latest）。
    @MainActor
    private func downloadFromPanel(url: URL) {
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let fileName = url.lastPathComponent
                let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let destURL = docsURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                await MainActor.run {
                    shareFileFromPanel(at: destURL)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func shareFileFromPanel(at url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
            popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        rootVC.present(activityVC, animated: true)
    }
}

// 源面板的行卡片：状态判定与源页横幅一致（已装/更新/插件已装）
@available(iOS 16.0, *)
private struct SourcePanelRow: View {
    let app: AltStoreSourceApp
    let onInstall: () -> Void
    let onDownload: () -> Void
    // 3.8.291：历史版本下载——点版本行下载该版本的 URL。
    let onDownloadVersion: (AltStoreSourceAppVersion) -> Void
    @ObservedObject private var sharedModel = DataManager.shared.model
    @ObservedObject private var pinnedStore = CZFPinnedAppsStore.shared
    @State private var copied = false
    // 3.8.292：两个 sheet 合并成一个 enum 驱动（同一视图挂两
    // 个 .sheet 只有一个会真正弹出，另一个静默失效；291 的版
    // 本单可能顶掉多开实例选择单）。打开处改 activeSheet =
    // .instances / .versions，关单处改 activeSheet = nil。
    @State private var activeSheet: RowSheet?

    // 3.8.292：行内 sheet 种类——多开实例选择 / 历史版本。
    private enum RowSheet: Identifiable {
        case instances, versions
        var id: Self { self }
    }

    private var isInstalled: Bool {
        (sharedModel.apps + sharedModel.hiddenApps).contains { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
    }

    // 注意：installedAppModel 只供 hasUpdate 版本比较；启动绝不走它
    //（多开时“打开”按下面 installedAppModels 走单开直启/多开选实例）。
    private var installedAppModel: LCAppModel? {
        (sharedModel.apps + sharedModel.hiddenApps).first(where: { $0.appInfo.bundleIdentifier() == app.bundleIdentifier })
    }

    private var installedAppModels: [LCAppModel] {
        (sharedModel.apps + sharedModel.hiddenApps).filter { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
    }

    private var hasUpdate: Bool {
        guard let sourceVersion = app.latestVersion?.version,
              let installed = installedAppModel else { return false }
        return Self.isVersion(sourceVersion, newerThan: installed.appInfo.version())
    }

    private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = b.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }

    private var isPlugin: Bool {
        app.latestVersion?.downloadURL.pathExtension.lowercased() == "dylib"
    }

    private var isPluginInstalled: Bool {
        guard let downloadURL = app.latestVersion?.downloadURL,
              downloadURL.pathExtension.lowercased() == "dylib" else { return false }
        let pluginURL = LCPath.tweakPath.appendingPathComponent(app.name).appendingPathComponent(downloadURL.lastPathComponent)
        return FileManager.default.fileExists(atPath: pluginURL.path)
    }

    // 3.8.342：metadataText 删——行只留名字，版本/Bundle ID
    // 不再显示（见 body），留着是死代码。
    // 3.8.292：行长按菜单抽成独立 @ViewBuilder 子表达式——
    // body 已很大（291 在 .contextMenu 处报 type '()' cannot
    // conform to 'View'，类型检查器扛不住）；内容一字不动，
    // 只换位置，body 里只留 `.contextMenu { rowContextMenu }`。
    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            pinnedStore.toggleSourcePin(app)
        } label: {
            Label(pinnedStore.isSourcePinned(app) ? "取消固定" : "固定到面板",
                  systemImage: pinnedStore.isSourcePinned(app) ? "pin.slash" : "pin")
        }
        Button {
            activeSheet = .versions
        } label: {
            Label("历史版本…", systemImage: "clock.arrow.circlepath")
        }
    }

    // 3.8.293：行动作按钮组抽成独立 @ViewBuilder 子表达式——
    // body 已超类型检查器上限（291 在 contextMenu、292 在
    // sheet 各报一次 type '()' cannot conform to 'View'，
    // 错永远落在链上最后一个 modifier）；内容一字不动，只换位置。
    @ViewBuilder
    private var rowActionButtons: some View {
        if let downloadURL = app.latestVersion?.downloadURL {
            Button {
                UIPasteboard.general.string = downloadURL.absoluteString
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(BasicButtonStyle())
        }
        Button {
            onDownload()
        } label: {
            Text("下载")
                .font(.system(size: 13)).bold()
                .foregroundColor(.white)
                .frame(height: 25)
                .padding(.horizontal, 10)
        }
        .buttonStyle(BasicButtonStyle())
        .background(Capsule().fill(Color.gray))
        .clipShape(Capsule())
        if isPlugin && isPluginInstalled {
            Text("已安装")
                .font(.system(size: 13)).bold()
                .foregroundColor(.white)
                .frame(height: 25)
                .padding(.horizontal, 10)
                .background(Capsule().fill(Color.green))
                .clipShape(Capsule())
        } else if !isPlugin && isInstalled && hasUpdate {
            Button {
                onInstall()
            } label: {
                Text("更新")
                    .font(.system(size: 13)).bold()
                    .foregroundColor(.white)
                    .frame(height: 25)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(BasicButtonStyle())
            .background(Capsule().fill(Color.orange))
            .clipShape(Capsule())
        } else if !isPlugin && isInstalled {
            Button {
                let matches = installedAppModels
                if matches.count == 1, let only = matches.first {
                    Task { try? await only.runApp() }
                } else if matches.count > 1 {
                    // 机制 2：多开时“打开”绝不静默取首个，多个实例弹实例选择
                    activeSheet = .instances
                }
            } label: {
                Text("打开")
                    .font(.system(size: 13)).bold()
                    .foregroundColor(.white)
                    .frame(height: 25)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(BasicButtonStyle())
            .background(Capsule().fill(Color.green))
            .clipShape(Capsule())
        } else {
            Button {
                onInstall()
            } label: {
                Text("安装")
                    .font(.system(size: 13)).bold()
                    .foregroundColor(.white)
                    .frame(height: 25)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(BasicButtonStyle())
            .background(Capsule().fill(Color.blue))
            .clipShape(Capsule())
        }
    }

    // 3.8.293：sheet 内容抽成独立 @ViewBuilder 函数——与上面
    // 同一原因；实例单与历史版本单原样搬入。
    @ViewBuilder
    private func sheetContent(for sheet: RowSheet) -> some View {
        switch sheet {
        case .instances:
            NavigationView {
                List(installedAppModels, id: \.self) { model in
                    Button {
                        activeSheet = nil
                        Task { try? await model.runApp() }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.appInfo.displayName())
                                .font(.system(size: 15)).bold()
                            Text("容器 \(model.uiSelectedContainer?.name ?? model.uiSelectedContainer?.folderName ?? "") • 版本 \(model.appInfo.version())")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("选择要打开的实例")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { activeSheet = nil }
                    }
                }
            }
        case .versions:
            SourceAppVersionsSheet(app: app, onDownloadVersion: onDownloadVersion)
        }
    }

    var body: some View {
        // 3.8.342：跟 App 面板一样干净整洁（用户 17:19 亲令）——
        // 只留名字一行，版本号/Bundle ID/描述全删（App 面板行
        // AppCardRow 只显名字，用户早定“版本号/包名/UUID 不再
        // 显示”）；图标 48→52、HStack 间距 12→8、名字改
        // subheadline 不加粗，与 AppCardRow 同款。按钮不动，
        // 还是下载/安装/打开/更新。
        HStack(spacing: 8) {
            AsyncImage(url: app.iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.25)
                }
            }
            .frame(width: 52, height: 52)
            // #15：圆角统一 12，跟顶部状态栏条/面板行同款（原来这里 10）
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(app.name)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            rowActionButtons
        }
        .padding(10)
        .background {
            // 3.8.301：行不用玻璃——ScrollView 里的玻璃行一滚动就
            // 画到固定头（运行条/搜索框）上面去（300 真机：源面板
            // 一滑，源行就盖住固定区/运行条）；玻璃只留给固定不动
            // 的铬（固定图标/运行条/搜索框），行一律走实色卡片。
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        }
        .contextMenu { rowContextMenu }
        .sheet(item: $activeSheet) { sheet in sheetContent(for: sheet) }
    }
}

// 3.8.291：源 App 历史版本单——逐行显版本/日期/大小/说明
//（与源详情页“版本信息”同款格式），点行下载该版本。
// versions 可能为空（源 JSON 无 versions 数组、顶层 downloadURL
// 也缺时），空时给一行提示，不留空白单。
@available(iOS 16.0, *)
private struct SourceAppVersionsSheet: View {
    let app: AltStoreSourceApp
    let onDownloadVersion: (AltStoreSourceAppVersion) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if app.versions.isEmpty {
                    Text("没有历史版本")
                        .foregroundColor(.secondary)
                } else {
                    List(app.versions) { version in
                        Button {
                            // 先关版本单再下载：分享框从 rootVC 弹出，
                            // 不与版本单叠在一起。
                            dismiss()
                            onDownloadVersion(version)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.version)
                                    .font(.subheadline).bold()
                                if let date = version.releaseDate {
                                    Text(date, style: .date)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let size = version.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let vdesc = version.localizedDescription, !vdesc.isEmpty {
                                    Text(vdesc)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle(app.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// 顶部状态栏（App 面板与源面板共用）：最前面是与快捷栏同款
// 的三个固定按钮（收起/最小化/关闭全部，用户要求加的），后面
// 横排已打开的 App：点按最大化打开，长按小窗口打开（用户定）。
// 整条放在浅色圆角底板上，与下面的列表卡片区分开（UI 美化）。
@available(iOS 16.0, *)
private struct RunningAppsStripView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    let onSwitch: () -> Void

    var body: some View {
        // 没运行 App 时三个按钮均分整行：原来横滑布局里三个
        // 按钮全挤左边、右边空一大截，怎么看怎么偏；有运行
        // App 时仍走横滑，不影响
        Group {
            if dockManager.apps.isEmpty {
                HStack {
                    Spacer()
                    collapseStripButton
                    Spacer()
                    minimizeAllStripButton
                    Spacer()
                    closeAllStripButton
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        collapseStripButton
                        minimizeAllStripButton
                        closeAllStripButton
                        // 分隔线定死 64 高（46 图标+4 间距+约
                        // 14 文字行高）：原来 50 比图标+文字矮
                        // 一截看着断开；改随内容撑满后高度成环
                        // 形依赖，横滑条把整条撑到约 200 高
                        // （用户点名“这么大”的根因），定死即破环
                        Divider()
                            .frame(height: 64)
                        ForEach(dockManager.apps) { runningApp in
                            runningAppItem(runningApp)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                // 横滑条锁死内容高：不锁的话高度一含糊就
                // 跟着面板往上撑（与分隔线是同一类毛病）
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 两态同高：没运行 App 是均分 HStack、有运行 App
        // 是横滑 ScrollView，量出来都是 46 图标+4 间距+
        // caption2 一行+上下各 6 ≈ 75；下限钉 78，两态
        // 一分不差，列表不跟着伸缩；只钉下限，大字号
        // 下内容长高仍能撑开，不裁字
        .frame(minHeight: 78)
        .modifier { content in
            // 3.8.289：运行条玻璃（样板图同款；App 面板共用
            // 此条，一并变玻璃）。非玻璃系统走原来浅灰底。
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                content.glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                content.background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    // 三个固定按钮：两态共用同一份定义，改一处即两态一致
    // （原来两边各写一遍，改漏一边就两态不一致）。布局
    // （均分 Spacer / 横滑间距）仍是各分支自己的事。
    private var collapseStripButton: some View {
        fixedButton(systemImage: "chevron.down", tile: Color(.systemGray5), glyph: .primary, label: "收起") {
            dockManager.toggleDockCollapse()
            onSwitch()
        }
    }
    private var minimizeAllStripButton: some View {
        fixedButton(systemImage: "rectangle.stack.badge.minus", tile: Color(.systemGray5), glyph: .primary, label: "最小化") {
            dockManager.minimizeAllWindows()
            onSwitch()
        }
    }
    private var closeAllStripButton: some View {
        fixedButton(systemImage: "xmark", tile: Color.red.opacity(0.12), glyph: .red, label: "关闭全部") {
            dockManager.closeAllWindows()
            onSwitch()
        }
    }

    // 固定按钮：浅底 + 深色图标（原来整块实心灰/红加白描边太
    // 重，用户点名丑）；关闭全部保留红色语义，但改浅红底红图标
    private func fixedButton(systemImage: String, tile: Color, glyph: Color, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tile)
                    .frame(width: 46, height: 46)
                Image(systemName: systemImage)
                    .foregroundColor(glyph)
                    .font(.system(size: 18, weight: .semibold))
            }
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }

    // 已打开的 App：点按切前台并最大化，长按切前台并小窗口
    // 打开。不用 Button 是免得长按时把点按也误触发（老毛病）。
    private func runningAppItem(_ runningApp: DockAppModel) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RunningAppIcon(appInfo: runningApp.appInfo)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 2)
                // 右上角小红 ✕：单独关掉这个 App（用户定）。
                // 高优先级手势独占这下点按，不触发图标本体的
                // 点按切换/长按小窗口；关掉后图标自动消失，
                // 面板不关（方便接着关下一个）
                ZStack {
                    Circle().fill(Color.red).frame(width: 18, height: 18)
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                }
                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                .contentShape(Circle())
                .highPriorityGesture(TapGesture().onEnded {
                    dockManager.closeAppWindow(uuid: runningApp.appUUID)
                })
                .offset(x: 5, y: -4)
            }
            Text(runningApp.appName)
                .font(.caption2)
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: 60)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            dockManager.maximizeWindow(uuid: runningApp.appUUID)
            onSwitch()
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            dockManager.restoreSmallWindow(uuid: runningApp.appUUID)
            onSwitch()
        }
    }
}

// 状态栏里的单个已打开 App 图标（异步加载方式与 AppCardRow 一致）
// 3.8.294：之前只写“与 AppCardRow 一致”，实际没走 IconCacheManager，
// 固定区图标全灰（点按有效、图标不见）——列表行走缓存先命中直接显，
// 这里每次都重解且加载时机不可靠。改成与 AppCardRow 同款：缓存键
// Bundle ID + dataUUID；onAppear 先查缓存命中直接用，未命中后台
// 解一次并写回；body 里也读一次缓存，列表已解进缓存时不用等
// onAppear 就直接显出来。
@available(iOS 16.0, *)
private struct RunningAppIcon: View {
    let appInfo: LCAppInfo?
    @State private var icon: UIImage?

    private var cacheKey: String {
        guard let appInfo = appInfo else { return "" }
        return "\(appInfo.bundleIdentifier() ?? "")_\(appInfo.dataUUID ?? "")"
    }
    private var cachedIcon: UIImage? {
        guard !cacheKey.isEmpty else { return nil }
        return IconCacheManager.shared.getIcon(for: cacheKey)
    }

    var body: some View {
        Group {
            if let icon = icon ?? cachedIcon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .onAppear { loadIcon() }
        // 3.8.295：再加 task 兜底——只靠 onAppear 时，若面板宿主
        // 在图标进缓存前就把视图建好、onAppear 已跑过，灰块要等
        // 父视图下次重渲染才消失；task 在视图重现与 cacheKey 变
        // 化时都会再跑一次，缓存一到就写回 @State。loadIcon 幂
        // 等（先查缓存命中直接用），两处触发不重复解图标。
        .task(id: cacheKey) { loadIcon() }
    }

    private func loadIcon() {
        // 已有图标不重复加载。
        if icon != nil { return }
        // 缓存命中也写回 @State（审计建议）：body 与 onAppear 是
        // 同一主线程 pass，若缓存恰在两者之间被别的行写进来，
        // 光 return 不设 State，灰块要等下次父视图重渲染才消失。
        if let cached = cachedIcon {
            self.icon = cached
            return
        }
        guard let appInfo = appInfo else { return }
        let key = cacheKey
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = appInfo.iconIsDarkIcon(false)
            if let loaded = loaded, !key.isEmpty {
                IconCacheManager.shared.setIcon(loaded, for: key)
            }
            DispatchQueue.main.async {
                self.icon = loaded
            }
        }
    }
}

// MARK: - App Card Row (same style as App tab)
@available(iOS 16.0, *)
struct AppCardRow: View {
    let app: LCAppModel
    let dockManager: MultitaskDockManager
    let onLaunch: () -> Void
    let onMinimizeOpen: () -> Void
    let onSmallWindowOpen: () -> Void
    @ObservedObject private var pinnedStore = CZFPinnedAppsStore.shared
    @State private var appIcon: UIImage?
    
    // 3.8.293：行长按菜单抽成独立 @ViewBuilder 子表达式——
    // body 已超类型检查器上限（292 在这里报 type '()' cannot
    // conform to 'View'）；内容一字不动，只换位置。
    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            pinnedStore.toggle(app)
        } label: {
            Label(pinnedStore.isPinned(app) ? "取消固定" : "固定到顶部",
                  systemImage: pinnedStore.isPinned(app) ? "pin.slash" : "pin")
        }
        if let uuid = app.appInfo.dataUUID,
           dockManager.apps.contains(where: { $0.appUUID == uuid }) {
            Button {
                dockManager.restartApp(uuid: uuid)
            } label: {
                Label("重启 App", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                dockManager.closeAppWindow(uuid: uuid)
            } label: {
                Label("关闭 App", systemImage: "xmark.circle")
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // App icon
            Group {
                if let icon = appIcon {
                    Image(uiImage: icon)
                        .resizable()
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear { loadIcon() }
            
            // 只显示 App 名字（用户要求：版本号/包名/UUID 不再显示）
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appInfo.displayName() ?? "Unknown")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // 次级动作统一中性灰胶囊（原来蓝/紫糖果色三件套太花，
            // 用户点名丑）；只有主动作「打开/启动」保留实心蓝
            Button(action: onMinimizeOpen) {
                Text("最小化")
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            Button(action: onSmallWindowOpen) {
                Text("小窗口")
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            // Launch button
            Button(action: onLaunch) {
                Text(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? "打开" : "启动")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background {
            // 3.8.301：行不用玻璃——与源 App 行同病：ScrollView 里
            // 的玻璃行一滚动就画到固定头上面去（300 真机源面板已
            // 实证）；玻璃只留给固定不动的铬，行一律走实色卡片。
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        }
        // 长按行：固定到面板顶部 / 取消固定（用户定）；
        // 正在运行的还多两个：重启（卡死时一步恢复）、关闭
        .contextMenu { rowContextMenu }
    }
    
    private func loadIcon() {
        // 卡片图标走共享缓存：LazyVStack 的行滑出滑回都会重新
        // onAppear，原来每次都重新解一次图标；先查缓存命中直接
        // 用，未命中才后台解一次并写回。键用 Bundle ID + dataUUID，
        // 与 dock 那边名字_UUID 的键不同，不会串深色/浅色图标。
        let cacheKey = "\(app.appInfo.bundleIdentifier() ?? "")_\(app.appInfo.dataUUID ?? "")"
        if let cached = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cached
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let icon = app.appInfo.iconIsDarkIcon(false)
            if let icon = icon {
                IconCacheManager.shared.setIcon(icon, for: cacheKey)
            }
            DispatchQueue.main.async {
                self.appIcon = icon
            }
        }
    }
}

// MARK: - Icon Cache Manager
// 面板图标缓存：原来是无上限字典，清理函数从没被
// 调过，图标只进不出。换 NSCache（200 个上限，
// 内存紧张时系统自动清），调用点一字不动。
class IconCacheManager {
    static let shared = IconCacheManager()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 200 }
    func getIcon(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }
    func setIcon(_ icon: UIImage, for key: String) {
        cache.setObject(icon, forKey: key as NSString)
    }
    func clearCache() {
        cache.removeAllObjects()
    }
}
// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        .onPressGesture(
            onPress: { 
                isPressed = true
            },
            onRelease: { location in 
                isPressed = false
                let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                impactFeedback.impactOccurred()
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: location)
            }
        )
        .contentShape(Rectangle())
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

// MARK: - 宿主 sendEvent 直读钩子（左滑出源面板专用，2026-11-04）
// 与客侧 TweakLoader 的 czf_sendEvent 同款：交换后本调用即原
// 实现，先原样转发，再纯观察（绝不拦截/改事件）。dynamic 必
// 须保留，否则 Swift 静态分发会自递归导致栈溢出。
extension UIWindow {
    @objc dynamic func czf_host_sendEvent(_ event: UIEvent) {
        self.czf_host_sendEvent(event)
        // MultitaskDockManager 带 @available(iOS 16.0, *)，文件级
        // extension 在类外、没有可用性上下文，直接引用会报
        // "'MultitaskDockManager' is only available in iOS 16.0 or
        // newer"（270 构建 #314 唯一红字）。照抄仓库既有 pattern
        // 包一层 #available，iOS 15 下跳过（管理器本身也不跑）。
        if #available(iOS 16.0, *) {
            MultitaskDockManager.czfHostOutwardObserve(window: self, event: event)
        }
    }
}

// MARK: - 3.8.308：源面板自定义设置快捷方式
// 可直开的设置页（deepLink host 与这里 rawValue 一一对应；
// LCSettingsView.handleURL 按 host 弹对应页）。
enum CZFSettingsPage: String, CaseIterable, Identifiable {
    case datamanagement
    case multitask
    case jit
    case multilc
    case storage
    case backup
    // 3.8.313：备份/恢复直达——都是 LCDataManagementView
    // 里的动作，用 initialSheet 让它一出现就弹出对应页；
    // 用户 19:06 令：恢复数据、选择备份进设置页，再加些
    // 重要的（备份全部、定时备份同组补齐）。
    case restore
    case selectbackup
    case backupall
    case schedulebackup
    // 3.8.317：快捷方式再加设置功能——插件/源/应用三
    // 个主页面此前不在选单里，点开是同款 sheet。
    case tweaks
    case sources
    case apps
    // 后台保活：点快捷方式直接开关，不用进设置页再翻找。
    case keepalive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .datamanagement: return "数据管理"
        case .multitask: return "多任务设置"
        case .jit: return "JIT 诊断"
        case .multilc: return "多开管理"
        case .storage: return "存储管理"
        case .backup: return "备份"
        case .restore: return "恢复数据"
        case .selectbackup: return "选择备份"
        case .backupall: return "备份全部"
        case .schedulebackup: return "定时备份"
        case .tweaks: return "插件管理"
        case .sources: return "源管理"
        case .apps: return "应用管理"
        case .keepalive: return "后台保活"
        }
    }

    var icon: String {
        switch self {
        case .datamanagement: return "externaldrive.fill"
        case .multitask: return "rectangle.stack"
        case .jit: return "wrench.and.screwdriver"
        case .multilc: return "apps.iphone"
        case .storage: return "internaldrive.fill"
        case .backup: return "archivebox.fill"
        case .restore: return "arrow.clockwise"
        case .selectbackup: return "checkmark.circle.fill"
        case .backupall: return "doc.on.doc"
        case .schedulebackup: return "clock.fill"
        case .tweaks: return "puzzlepiece"
        case .sources: return "books.vertical"
        case .apps: return "square.stack.3d.up.fill"
        case .keepalive: return "heart.fill"
        }
    }

    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .datamanagement: LCDataManagementView()
        case .multitask: LCMultitaskSettingView()
        case .jit: LCJITLessDiagnoseView()
        case .multilc: LCMultiLCManagementView()
        case .storage: LCStorageManagementView()
        case .backup: LCDataManagementView()
        case .restore: LCDataManagementView(initialSheet: .restore)
        case .selectbackup: LCDataManagementView(initialSheet: .backupSelect)
        case .backupall: LCDataManagementView(initialSheet: .backupAll)
        case .schedulebackup: LCDataManagementView(initialSheet: .scheduleBackup)
        case .tweaks: LCTweaksView()
        case .sources: LCSourcesView()
        case .apps: LCAppListView()
        case .keepalive: CZFKeepAliveShortcutView()
        }
    }
}

// 后台保活快捷方式的目的页：只放保活开关本身（与设置页
// keepAliveSection 同款：同一把 @AppStorage 键
// LCKeepAliveEnabled，同一套 onChange/onAppear 同步），
// 点快捷方式直接开关，不用进设置页再翻找。
private struct CZFKeepAliveShortcutView: View {
    @AppStorage("LCKeepAliveEnabled") private var keepAliveEnabled = true

    var body: some View {
        Form {
            Section(header: Text("后台保活")) {
                Toggle(isOn: $keepAliveEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "heart.fill", color: .red)
                        Text("保活（无声音频）")
                    }
                }
                .onChange(of: keepAliveEnabled) { newValue in
                    LCSettingsView.syncKeepAliveTweak(enabled: newValue, forceSign: false)
                    CZFHostKeepAlive.shared.refresh()
                }
                .onAppear {
                    LCSettingsView.syncKeepAliveTweak(enabled: keepAliveEnabled, forceSign: false)
                    CZFHostKeepAlive.shared.refresh()
                }
            }
        }
    }
}

// 3.8.311：自定义快捷方式（可添加多个单独图标）——
// 用户 17:30 纠正：要的不是加 App 快捷（点图标启动 App），
// 而是把 APP 详情页里的设置加为快捷方式——某个 App 的
// 某个开关/设置。分两类：
// - 设置页：存 "page:<rawValue>"，点开对应设置页；
// - App 设置：存 "setting:<pinKey>:<key>"（pinKey = 包名
//   _dataUUID，key 是 CZFPanelAppSetting 的 rawValue），
//   开关类点按直接切换，多选项类点按打开该 App 的设置页。
// 存 UserDefaults 数组，按添加顺序排；长按图标可移除。
// 3.8.316：快捷行拖动调序代理——同 CZFPinnedReorderDelegate
// 的路：拖过目标即换位。items 是面板的 @State 镜像，换位后
// 同时写回 CZFPanelCustomShortcuts（UserDefaults），下次打
// 开面板与导出设置都按新顺序走。
private struct CZFCustomShortcutReorderDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var items: [String]
    @Binding var draggedKey: String?

    func dropEntered(info: DropInfo) {
        guard let draggedKey = draggedKey,
              items.indices.contains(targetIndex),
              items[targetIndex] != draggedKey,
              let from = items.firstIndex(of: draggedKey) else { return }
        CZFPanelCustomShortcuts.move(from: from, to: targetIndex)
        items = CZFPanelCustomShortcuts.items
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKey = nil
        return true
    }
}

enum CZFPanelCustomShortcuts {
    static let key = "CZFPanelCustomShortcuts"
    private static let legacyKey = "CZFPanelCustomSettingsPage"

    static var items: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func pageItem(_ raw: String) -> String { "page:\(raw)" }
    static func settingItem(pinKey: String, key: String) -> String { "setting:\(pinKey):\(key)" }

    static func pageRaw(from item: String) -> String? {
        guard item.hasPrefix("page:") else { return nil }
        return String(item.dropFirst(5))
    }

    static func settingPinKeyAndKey(from item: String) -> (pinKey: String, key: String)? {
        guard item.hasPrefix("setting:") else { return nil }
        let parts = item.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[1]), String(parts[2]))
    }

    static func contains(_ item: String) -> Bool {
        items.contains(item)
    }

    static func add(_ item: String) {
        var list = items
        if !list.contains(item) {
            list.append(item)
            items = list
        }
    }

    static func remove(_ item: String) {
        items = items.filter { $0 != item }
    }

    // 3.8.316：拖动调序——同 CZFPinnedAppsStore.movePinned 的路
    // （remove + insert），换位后直接写回 UserDefaults。
    static func move(from source: Int, to destination: Int) {
        var list = items
        guard source != destination,
              list.indices.contains(source),
              destination >= 0, destination < list.count else { return }
        let item = list.remove(at: source)
        list.insert(item, at: destination)
        items = list
    }

    // 旧版单自定义迁移：309 只存一个设置页 rawValue，第一次
    // 读到新数组为空且旧值还在时，把旧值搬进数组并清掉旧键。
    // 3.8.311：310 的 "app:" 启动快捷是误读（用户不要），
    // 一并清掉，不留死条目。
    static func migrateIfNeeded() {
        let cleaned = items.filter { !$0.hasPrefix("app:") }
        if cleaned.count != items.count {
            items = cleaned
        }
        guard items.isEmpty else { return }
        if let old = UserDefaults.standard.string(forKey: legacyKey) {
            items = [pageItem(old)]
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}

// 3.8.311：App 设置快捷方式的目录——某个 App 的某个设置。
// 开关类（isToggle）点按直接切换；多选项类点按打开该 App
// 的设置页（语言、多任务、模块文件夹、容器等都在那页上）。
enum CZFPanelAppSetting: String, CaseIterable {
    case schedMin = "schedmin"
    case fixNotify = "fixnotify"
    case vpn = "vpn"
    case keepAlive = "keepalive"
    case jit = "jit"
    case fixPicker = "fixpicker"
    case openSettings = "opensettings"
    // 3.8.312：设置页再加设置——把 App 设置页里剩下
    // 的纯开关也放进快捷方式（都是 LCAppModel 上带 didSet
    // 直写 appInfo 的布尔开关，点按直接 toggle 即生效，
    // 与已有的 fixNotify/fixPicker/jit 同款；锁定/隐藏
    // 不加——它俩要走 setLocked/toggleHidden 异步流程，
    // 还有刷脸与 delegate 关导航，直接 toggle 会不同步）。
    case useLCBundleId = "uselcbundleid"
    case hideLiveContainer = "hidelivecontainer"
    case classicMode = "classicmode"
    case spoofSDK = "spoofsdk"
    case symlinkInbox = "symlinkinbox"
    case dontInjectTweak = "dontinjecttweak"

    var title: String {
        switch self {
        case .schedMin: return "定时最小化打开"
        case .fixNotify: return "修复本地通知"
        case .vpn: return "单 App VPN"
        case .keepAlive: return "保活"
        case .jit: return "JIT 启动"
        case .fixPicker: return "修复文件选择器"
        case .openSettings: return "打开 App 设置页"
        case .useLCBundleId: return "用 LC Bundle ID"
        case .hideLiveContainer: return "隐藏 LiveContainer"
        case .classicMode: return "兼容模式"
        case .spoofSDK: return "伪装 SDK 版本"
        case .symlinkInbox: return "软链 Inbox"
        case .dontInjectTweak: return "不注入 TweakLoader"
        }
    }

    var icon: String {
        switch self {
        case .schedMin: return "clock.fill"
        case .fixNotify: return "bell.fill"
        case .vpn: return "shield.fill"
        case .keepAlive: return "heart.fill"
        case .jit: return "bolt.fill"
        case .fixPicker: return "folder.fill"
        case .openSettings: return "gearshape.fill"
        case .useLCBundleId: return "app.badge"
        case .hideLiveContainer: return "eye.slash"
        case .classicMode: return "rectangle.on.rectangle"
        case .spoofSDK: return "hammer.fill"
        case .symlinkInbox: return "link"
        case .dontInjectTweak: return "nosign"
        }
    }

    /// 是否开关类（点按直接切换）；false = 多选项类（点按打开 App 设置页）。
    var isToggle: Bool { self != .openSettings }
}

// 3.8.311：添加自定义快捷方式——两区：设置页 + App 设置。
// 设置页点一个就加进快捷行；App 设置是两级：先挑 App，
// 再挑它的某个设置（开关类 / 打开设置页）。
@available(iOS 16.0, *)
private struct CZFPanelCustomSettingsPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var installedApps: [LCAppModel] {
        LCAppSortManager.shared.sortedApps
    }

    var body: some View {
        NavigationView {
            List {
                Section("设置页") {
                    ForEach(CZFSettingsPage.allCases) { page in
                        let item = CZFPanelCustomShortcuts.pageItem(page.rawValue)
                        Button {
                            onPick(item)
                        } label: {
                            HStack {
                                Image(systemName: page.icon)
                                    .foregroundColor(.blue)
                                Text(page.title)
                                Spacer()
                                if CZFPanelCustomShortcuts.contains(item) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
                Section("App 设置") {
                    ForEach(installedApps, id: \.self) { app in
                        NavigationLink {
                            CZFPanelAppSettingListView(app: app, onPick: onPick)
                        } label: {
                            HStack {
                                RunningAppIcon(appInfo: app.appInfo)
                                    .frame(width: 28, height: 28)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(app.appInfo.displayName() ?? "")
                            }
                        }
                    }
                }
            }
            .navigationTitle("添加快捷方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// 3.8.311：某个 App 的设置列表（选页单第二级）——
// 上区是开关类（点按直接切换），下区是打开该 App 的设置页
//（语言、多任务、模块文件夹、容器等都在那页上）。
@available(iOS 16.0, *)
private struct CZFPanelAppSettingListView: View {
    let app: LCAppModel
    let onPick: (String) -> Void

    private var pinKey: String {
        CZFPinnedAppsStore.pinKey(for: app)
    }

    var body: some View {
        List {
            Section("开关") {
                ForEach(CZFPanelAppSetting.allCases.filter { $0.isToggle }, id: \.self) { setting in
                    let item = CZFPanelCustomShortcuts.settingItem(pinKey: pinKey, key: setting.rawValue)
                    Button {
                        onPick(item)
                    } label: {
                        HStack {
                            Image(systemName: setting.icon)
                                .foregroundColor(.blue)
                            Text(setting.title)
                            Spacer()
                            if CZFPanelCustomShortcuts.contains(item) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            Section("设置页") {
                let setting = CZFPanelAppSetting.openSettings
                let item = CZFPanelCustomShortcuts.settingItem(pinKey: pinKey, key: setting.rawValue)
                Button {
                    onPick(item)
                } label: {
                    HStack {
                        Image(systemName: setting.icon)
                            .foregroundColor(.blue)
                        Text(setting.title)
                        Spacer()
                        if CZFPanelCustomShortcuts.contains(item) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle(app.appInfo.displayName() ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}
