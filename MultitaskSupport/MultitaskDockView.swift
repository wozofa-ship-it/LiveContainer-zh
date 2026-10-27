//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

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
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
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
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
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
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
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
    
    // 同时运行上限（CZF）：最多 3 个窗口。第 4 个窗口注册时
    // 才触发（App 页点开、快捷栏点开都走 addRunningAppWithInfo
    // 注册，所以两条路都拦得到；已在运行的点回来不算新注册）。
    // 候选只认已最小化的窗口：可见的不动、画中画豁免、没有
    // 最小化候选时不强制关可见窗口（上限此时是软上限，允许
    // 第 4 个留着）。弹确认，点了“关闭并继续”才关最久最小
    // 化的那个，点了“不开了”就关掉刚开的这个新窗口。
    private func czfEnforceRunningCap(newUUID: String) {
        guard apps.count > 3, !czfCapAlertShowing else { return }
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
            if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(bundlePath)") {
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

    private func checkScheduledMinimizeOpen() {
        let defaults = UserDefaults.standard
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())
        let cal = Calendar.current
        let now = Date()
        let nowTotal = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        for app in allApps {
            guard let bundleId = app.appInfo.bundleIdentifier() else { continue }
            guard defaults.bool(forKey: "CZFSchedMinEnabled-\(bundleId)") else { continue }
            if defaults.string(forKey: "CZFSchedMinLastDate-\(bundleId)") == today { continue }
            let target = defaults.integer(forKey: "CZFSchedMinMinutes-\(bundleId)")
            if nowTotal < target { continue }
            guard let dataUUID = app.appInfo.dataUUID,
                  let bundlePath = app.appInfo.relativeBundlePath else { continue }
            // 先记账再打开，防同一天重复触发
            defaults.set(today, forKey: "CZFSchedMinLastDate-\(bundleId)")
            czfMinimizeOpenApp(dataUUID: dataUUID, bundlePath: bundlePath)
            break
        }
    }

    // 与快捷栏面板的「最小化打开」同一套路：已在运行直接最小化窗口；
    // 未运行先走 launch URL 拉起，再轮询等窗口出现后最小化。
    private func czfMinimizeOpenApp(dataUUID: String, bundlePath: String) {
        if apps.contains(where: { $0.appUUID == dataUUID }) {
            minimizeWindow(uuid: dataUUID)
            return
        }
        if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(bundlePath)") {
            #if !os(visionOS)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            #endif
        }
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            attempts += 1
            guard let self else {
                timer.invalidate()
                return
            }
            if self.apps.contains(where: { $0.appUUID == dataUUID }) {
                self.minimizeWindow(uuid: dataUUID)
                timer.invalidate()
            } else if attempts >= 40 {
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

    private func checkMinAutoClose() {
        let defaults = LCUtils.appGroupUserDefault
        let enabled = defaults.object(forKey: "CZFMinAutoCloseEnabled") == nil || defaults.bool(forKey: "CZFMinAutoCloseEnabled")
        guard enabled else {
            czfMinimizedSince.removeAll()
            return
        }
        // 自动关时长（CZF，可调）：设置页“最小化省电”里选
        // 10 / 30 / 60 分钟，默认 30 分钟（以前写死 1800 秒）。
        // integer(forKey:) 键不存在时返回 0，正好落到默认 30。
        let closeMinutes = defaults.integer(forKey: "CZFMinAutoCloseMinutes")
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
            // 只认真正藏起来的：动画中途 alpha 为 0 但 hidden 还没置位
            // 时不算，避免 0.3 秒动画就开始计时。
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
    private var globalSwipeObserversInstalled = false
    // 边缘手势一次性闩锁：一次拖动只触发一次动作（源面板入口带震动，
    // 不闩住会在 .changed 里连震好几下）
    private var czfEdgeSwipeLatched = false

    private func setupGlobalSwipeRecognizer() {
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
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand, !czfEdgeSwipeLatched else { return }
            if processGlobalSwipe(startEdge: globalSwipeStartEdge, translation: translation, endX: endX, width: width) {
                czfEdgeSwipeLatched = true
            }
        case .ended, .cancelled:
            defer { czfEdgeSwipeLatched = false }
            guard globalSwipeStartEdge == 0 || globalSwipeStartInBand, !czfEdgeSwipeLatched else { return }
            processGlobalSwipeFallback(startEdge: globalSwipeStartEdge, translation: translation, endX: endX, width: width)
        default:
            break
        }
    }

    // 终结兜底判定：与 TweakLoader 内手势触摸漏斗的终结规则同参。
    // 只认边缘起手；任意位置起手不兜底（防误触设计不变）。
    private func processGlobalSwipeFallback(startEdge: Int, translation: CGPoint, endX: CGFloat, width: CGFloat) {
        let dx = translation.x
        let dy = translation.y
        let s = Self.czfThresholdScale
        if startEdge == 1 {
            // 2026-10-23 真机纠正后对调：左边缘往里拖（手指右移）
            // = App 面板，往外弹（手指左移）= 源面板。门槛跟着动作
            // 的物理方向走，不跟面板走（往里拖与 App 内横滑同轨，
            // 门槛保持严；往外弹空间小，门槛保持松）
            if dx <= -8 * s, endX <= 12, abs(dx) > 0.4 * abs(dy) {
                fireDockAction { self.czfOpenSourcesPanel() }
            } else if dx >= 44 * s, abs(dx) > 0.8 * abs(dy) {
                fireDockAction { self.czfOpenAppPanel() }
            }
        } else if startEdge == 2 {
            if dx >= 8 * s, endX >= width - 12, abs(dx) > 0.4 * abs(dy) {
                fireDockAction { self.czfEdgeRightOutward() }
            } else if dx <= -44 * s, abs(dx) > 0.8 * abs(dy) {
                fireDockAction { self.czfEdgeRightInward() }
            }
        }
    }

    // 手势判定核心：宿主窗口手势与悬浮边条窗共用。
    // startEdge：0=任意位置 1=左边缘 2=右边缘；往外滑门槛低（手指很快滑出屏幕）。
    // 返回 true 表示本次判定触发了动作（边条 handler 据此做一次性触发）
    @discardableResult
    private func processGlobalSwipe(startEdge: Int, translation: CGPoint, endX: CGFloat, width: CGFloat) -> Bool {
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
            if draggingRight {
                guard translation.x > 30 * s else { return false }
                fireDockAction { self.czfOpenAppPanel() }
            } else {
                guard abs(translation.x) > 6 * s else { return false }
                fireDockAction { self.czfOpenSourcesPanel() }
            }
            return true
        } else {
            // 任意位置起手：拖到屏幕边缘、位移 >50 才算隐藏
            guard abs(translation.x) > 50 else { return false }
            if draggingRight && endX >= width - 30 {
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

    // 全部接收、只记录起手位置；触发判定在 handler 里按起手+落点做
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 屏幕边缘识别器（栏隐藏时的 UIScreenEdgePan）：按启用带
        // 放行，带外的触摸直接不让它识别。
        if gestureRecognizer is UIScreenEdgePanGestureRecognizer,
           let window = gestureRecognizer.view as? UIWindow {
            let y = touch.location(in: window).y
            let height = window.bounds.height
            return y >= height * Self.czfEdgeBandTop && y <= height * Self.czfEdgeBandBottom
        }
        guard globalSwipeRecognizers.contains(where: { $0 === gestureRecognizer }),
              let window = gestureRecognizer.view as? UIWindow else { return true }
        let loc = touch.location(in: window)
        let height = window.bounds.height
        globalSwipeStartInBand = loc.y >= height * Self.czfEdgeBandTop && loc.y <= height * Self.czfEdgeBandBottom
        if loc.x >= window.bounds.width - 44 {
            globalSwipeStartEdge = 2
        } else if loc.x <= 44 {
            globalSwipeStartEdge = 1
        } else {
            globalSwipeStartEdge = 0
        }
        return true
    }

    // 全局甩动手势只观察、不同步拦截：与 App 自己的手势同时识别
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return globalSwipeRecognizers.contains { $0 === gestureRecognizer }
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
    // 开关下第二下会把刚打开的面板又关掉，还多震一下。0.4 秒内
    // 的重复调用直接吞掉，一次滑动只算一次。两个面板共用一个
    // 时间戳（互斥呈现，连着误报两边也只认第一下）。
    private var czfLastPanelActionAt = Date.distantPast

    @objc public func czfOpenAppPanel() {
        guard Self.czfEdgeGesturesEnabled else { return }
        // 不再要求已打开 App/快捷栏可见：用户定任意位置（包括刚
        // 进 LiveContainer 的主界面）都要能调出面板，与源面板同
        // 待遇。呈现走 keyWindow 兜底（presentAllAppsPanel 内）。
        let now = Date()
        guard now.timeIntervalSince(czfLastPanelActionAt) > 0.4 else { return }
        czfLastPanelActionAt = now
        edgeCallbackBuzz()
        // 切换式（用户要求）：面板已打开再滑一次就关掉，
        // 不再是只能滑开、关还得点按钮/点遮罩。
        if isAppPanelOpen {
            dismissPanelOverlay()
            return
        }
        presentAllAppsPanel()
    }

    // 源面板入口：左边缘往外弹（手指左移）调出（2026-10-23
    // 对调后，与往里拖的 App 面板对称）。故意不加 isVisible/
    // !apps 守卫：没打开任何 App、在主界面时也要能调出（用户
    // 明确要求）；呈现走 keyWindow 兜底。同样是切换式：已打开
    // 再滑一次关掉。
    @objc public func czfOpenSourcesPanel() {
        guard Self.czfEdgeGesturesEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(czfLastPanelActionAt) > 0.4 else { return }
        czfLastPanelActionAt = now
        edgeCallbackBuzz()
        if isSourcesPanelOpen {
            dismissSourcesOverlay()
            return
        }
        presentSourcesPanel()
    }


    // 建好手势面板覆盖层（只建一次，常驻窗口待命，和快捷栏同一个生命周期）。
    // #89 是每次左滑现建 SwiftUI 视图树：首帧渲染慢，滑完要等一下才动，
    // 体感像失灵；且开/关状态只认存着的引用，视图一旦被外部摘掉引用还
    // 非空，之后永远弹不出（小窗口"有时行有时不行"）。常驻后开/关只改
    // 可见性和位置，状态以视图 isHidden 为准，不再被旧引用毒化。
    private func ensurePanelOverlay(in window: UIWindow) {
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
        // 面板本体：底部 60% 高，上圆角（75% 版 2026-10-23 当晚被
        // 用户真机否决：又高又肿，且整条盖死源面板手势起手带）
        let rootView = AnyView(
            AllAppsListView()
                .environmentObject(self)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissPanelOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.6)
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

    private func presentAllAppsPanel() {
        DispatchQueue.main.async {
            guard let window = self.hostingController?.view.window ?? self.keyWindow else { return }
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
            let panelHeight = b.height * 0.6
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != panelHeight {
                host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: panelHeight)
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = CGRect(x: 0, y: b.height - panelHeight, width: b.width, height: panelHeight)
            }
        }
    }

    @objc private func czfPanelBackdropTapped() {
        dismissPanelOverlay()
    }

    // 面板下滑关闭的起手限制：只认面板顶部 52pt 标题区，
    // 面板内的列表滚动一点不受影响；其余手势一律放行。
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let hostView = gestureRecognizer.view,
           hostView === czfPanelOverlayHost?.view || hostView === czfSourcesOverlayHost?.view {
            return gestureRecognizer.location(in: hostView).y < 52
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
        let openY = container.bounds.height - panelHeight
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
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame = host.view.frame.offsetBy(dx: 0, dy: height)
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
        })
    }

    // MARK: - 源面板覆盖层（与 App 面板同构：常驻待命、强制对齐呈现）

    private func ensureSourcesOverlay(in window: UIWindow) {
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
                .environment(\.czfPanelClose) { [weak self] in self?.dismissSourcesOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.6)
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
            guard let window = self.hostingController?.view.window ?? self.keyWindow else { return }
            // 两个面板互斥：开这个先关那个
            self.dismissPanelOverlay()
            self.ensureSourcesOverlay(in: window)
            guard let host = self.czfSourcesOverlayHost, let backdrop = self.czfSourcesOverlayBackdrop else { return }
            // 计数 +1：面板视图据此刷新源数据（覆盖层常驻，onAppear 不重来）
            self.czfSourcesPanelOpenCounter += 1
            window.bringSubviewToFront(backdrop)
            window.bringSubviewToFront(host.view)
            let b = window.bounds
            let panelHeight = b.height * 0.6
            backdrop.frame = b
            backdrop.isHidden = false
            host.view.isHidden = false
            if host.view.frame.height != panelHeight {
                host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: panelHeight)
            }
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.6, options: [.curveEaseOut]) {
                backdrop.alpha = 1
                host.view.frame = CGRect(x: 0, y: b.height - panelHeight, width: b.width, height: panelHeight)
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
            guard let window = self.hostingController?.view.window ?? self.keyWindow else { return }
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
            let panelHeight = b.height * 0.6
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
                oldHost.view.frame = oldHost.view.frame.offsetBy(dx: 0, dy: oldHeight)
                newHost.view.frame = CGRect(x: 0, y: b.height - panelHeight, width: b.width, height: panelHeight)
            } completion: { _ in
                oldBackdrop.isHidden = true
                oldHost.view.isHidden = true
            }
        }
    }

    @objc private func czfAppPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        switchPanels(toSources: true)
    }

    @objc private func czfSourcesPanelEdgeSwitched(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        switchPanels(toSources: false)
    }

    @objc private func czfSourcesBackdropTapped() {
        dismissSourcesOverlay()
    }

    private func dismissSourcesOverlay() {
        guard let host = czfSourcesOverlayHost, let backdrop = czfSourcesOverlayBackdrop, !host.view.isHidden else { return }
        let height = host.view.frame.height
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn], animations: {
            backdrop.alpha = 0
            host.view.frame = host.view.frame.offsetBy(dx: 0, dy: height)
        }, completion: { _ in
            backdrop.isHidden = true
            host.view.isHidden = true
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
                    case "czf.dock.openPanel": manager.czfOpenAppPanel()
                    case "czf.dock.openSources": manager.czfOpenSourcesPanel()
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
                AllAppsListView()
                    // 只留一个半屏档位：两个档位时系统会先拉高抽屉、列表滚不动
                    .presentationDetents([.fraction(0.6)])
                    .presentationDragIndicator(.visible)
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
// 按 bundleIdentifier 记（重装不丢），存 App Group 默认设置。
final class CZFPinnedAppsStore: ObservableObject {
    static let shared = CZFPinnedAppsStore()
    @Published private(set) var pinnedIds: [String] = []
    private let defaultsKey = "CZFPinnedPanelApps"
    init() {
        pinnedIds = LCUtils.appGroupUserDefault.stringArray(forKey: defaultsKey) ?? []
    }
    func isPinned(_ id: String) -> Bool { pinnedIds.contains(id) }
    func toggle(_ id: String) {
        if let idx = pinnedIds.firstIndex(of: id) {
            pinnedIds.remove(at: idx)
        } else {
            pinnedIds.append(id)
        }
        LCUtils.appGroupUserDefault.set(pinnedIds, forKey: defaultsKey)
    }
}

// 面板顶部固定区：直接贴面板底色排版，不套灰卡；图标
// 横排，点按打开；没固定过时给一行提示怎么固定。
// 视觉对齐（2026-10-24）：面板三段统一外边距 16、内容列
// 对齐到 26（外 16 + 内 10，与运行条、列表行图标列同线）、
// 段间距统一 10；固定区图标行单独内缩 10，标题行不动
// （标题对齐卡片背景边，图标对齐图标列）。
@available(iOS 16.0, *)
struct PinnedAppsStripView: View {
    @ObservedObject var sortManager = LCAppSortManager.shared
    @ObservedObject var pinnedStore = CZFPinnedAppsStore.shared
    let onLaunch: (LCAppModel) -> Void
    let onClose: () -> Void

    private var pinnedApps: [LCAppModel] {
        sortManager.sortedApps.filter { pinnedStore.isPinned($0.appInfo.bundleIdentifier() ?? "") }
    }

    var body: some View {
        // 直接贴面板底色排版，不再套一层灰卡（卡里套卡是用户
        // 点名"太丑"的主因）；图标 40pt / 圆角 12（用户定小点），
        // 运行区 46pt、列表行 52pt，左边缘对齐即可
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                // “固定”俩字已去掉（用户定）：只留图钉标示，
                // 标题行不占字，看着干净
                Image(systemName: "pin.fill")
                    .font(.caption2)
                Spacer()
                // 关闭钮并进这一行（原来单独占一整行顶栏，顶部
                // 一层叠一层，用户点名挤）；动作与原 ✕ 相同
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                }
            }
            .foregroundColor(.secondary)
            if pinnedApps.isEmpty {
                Text("长按下面的 App 可以固定到这里")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(pinnedApps, id: \.self) { app in
                            // 固定区只留图标、不要名字（用户定）：名字
                            // 字号小又挤，图标本身已够认；点按仍打开
                            RunningAppIcon(appInfo: app.appInfo)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
                                .contentShape(Rectangle())
                                .onTapGesture { onLaunch(app) }
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
    }
}

@available(iOS 16.0, *)
struct AllAppsListView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.czfPanelClose) private var czfPanelClose
    @EnvironmentObject var dockManager: MultitaskDockManager

    // 关闭面板：覆盖层（手势弹出）走注入的关闭动作；sheet（点蓝图标）走 dismiss
    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }
    @ObservedObject var sortManager = LCAppSortManager.shared

    var body: some View {
        // 不用 NavigationView：空标题的导航栏白占一条高度，面板
        // 本来就只有半屏多；原来挂的 .searchable 绑的是常量空串
        // （根本不筛选），iOS 26 还把它渲染成悬浮条压在面板底部，
        // 遮住最后一行（用户真机点名"一拉出来都遮挡住了"）。改成
        // 关闭钮并进固定区标题行：独立顶栏又是一层，顶部
        // 顶栏+固定+运行三层叠着（用户点名），省下的高度
        // 全留给列表
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 顶部固定区（用户定）：不要"App"标题，换成可固定
                // 的 App 小图标横排（长按下面列表行固定/取消），
                // 固定区不随列表滚动
                PinnedAppsStripView(onLaunch: { app in launchApp(app) }, onClose: { closePanel() })
                // 状态栏条固定在顶部，不随列表滚动（原来在
                // ScrollView 里，往下翻卡片后收起/最小化/
                // 关闭全部就没了，得翻回顶部）
                RunningAppsStripView { closePanel() }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(sortManager.sortedApps, id: \.self) { app in
                        AppCardRow(app: app, dockManager: dockManager, onLaunch: {
                            launchApp(app)
                        }, onMinimizeOpen: {
                            minimizeOpenApp(app)
                        }, onSmallWindowOpen: {
                            smallWindowOpenApp(app)
                        })
                    }
                }
                // 列表外边距显式写死 16：与固定区、运行条外边距
                // 同线；顶部不留白，运行条底 10 就是段间距
                .padding([.horizontal, .bottom], 16)
                .id("czfAppPanelTop")
            }
            .onChange(of: dockManager.czfAppPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置）
                proxy.scrollTo("czfAppPanelTop", anchor: .top)
            }
            }
        }
    }
    
    private func launchApp(_ app: LCAppModel) {
        let bundleId = app.appInfo.relativeBundlePath ?? ""
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == app.appInfo.dataUUID }) {
            // 窗口必须属于本条目：同包名别的条目若共用容器，
            // 按 dataUUID 找会把别人的窗口顶回来；归属对不上
            // 就不顶，走下面 URL 启动，runApp 里会拆共享容器。
            let belongsToOther = runningApp.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 != app.appInfo.relativeBundlePath } ?? false
            if !belongsToOther {
                let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                closePanel()
                return
            }
        }
        if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(bundleId)") {
            #if !os(visionOS)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            #endif
        }
        closePanel()
    }
    
    private func minimizeOpenApp(_ app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        // 如果已在运行，直接最小化它的窗口
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
            let belongsToOther = runningApp.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 != app.appInfo.relativeBundlePath } ?? false
            if !belongsToOther {
                dockManager.minimizeWindow(uuid: runningApp.appUUID)
                closePanel()
                return
            }
        }        // 未运行：先启动，延迟后最小化窗口
        closePanel()
        let bundleId = app.appInfo.relativeBundlePath ?? ""
        if let url = URL(string: "livecontainer://livecontainer-launch?bundle-name=\(bundleId)") {
            #if !os(visionOS)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            #endif
        }
        // 主线程轮询等待窗口出现，找到后最小化
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            if self.dockManager.apps.contains(where: { $0.appUUID == dataUUID }) {
                self.dockManager.minimizeWindow(uuid: dataUUID)
                timer.invalidate()
            } else if attempts >= 20 {
                timer.invalidate()
            }
        }
    }

    // 直接以小窗口（多任务）打开：窗口若被设置成最大化打开，还原成小窗口尺寸
    private func smallWindowOpenApp(_ app: LCAppModel) {
        guard let dataUUID = app.appInfo.dataUUID else { return }
        // 已在运行：把它的窗口带到前面，并还原为小窗口
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == dataUUID }) {
            let belongsToOther = runningApp.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 != app.appInfo.relativeBundlePath } ?? false
            if !belongsToOther {
                let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
                unmaximizeWindow(uuid: dataUUID)
                closePanel()
                return
            }
        }
        closePanel()
        Task {
            try? await app.runApp(multitask: true, containerFolderName: dataUUID)
        }
        // 等窗口建好后还原为小窗口（轮询窗口出现）
        var attempts = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
            attempts += 1
            if self.dockManager.apps.contains(where: { $0.appUUID == dataUUID }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.unmaximizeWindow(uuid: dataUUID)
                }
                timer.invalidate()
            } else if attempts >= 30 {
                timer.invalidate()
            }
        }
    }

    private func unmaximizeWindow(uuid: String) {
        guard let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
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

    private func closePanel() {
        if let czfPanelClose = czfPanelClose {
            czfPanelClose()
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 状态栏条固定在顶部，不随列表滚动（与 App 面板一致）
                RunningAppsStripView { closePanel() }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // 滚回顶部锚点（条子已挪到 ScrollView 外面，
                    // 这里留个 0 高锚点，调出面板仍滚回最顶部）
                    Color.clear.frame(height: 0).id("czfSourcesPanelTop")
                    if viewModel.sources.isEmpty {
                        Text("还没有添加源")
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    ForEach(viewModel.sources) { item in
                        if let source = item.source {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(source.name)
                                    .font(.headline)
                                    .padding(.horizontal)
                                ForEach(source.apps) { app in
                                    SourcePanelRow(app: app, onInstall: { installFromPanel(app: app) }, onDownload: { downloadFromPanel(app: app) })
                                        .padding(.horizontal)
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
            .navigationTitle("源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { closePanel() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.refreshAllSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onChange(of: dockManager.czfSourcesPanelOpenCounter) { _ in
                // 每次调出回到初始状态：滚回最顶部（用户定，
                // 不留上次滑动的位置）+ 刷新源数据
                proxy.scrollTo("czfSourcesPanelTop", anchor: .top)
                Task { await viewModel.refreshAllSources() }
            }
            .alert("提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            }
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
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let fileName = downloadURL.lastPathComponent
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
    @ObservedObject private var sharedModel = DataManager.shared.model
    @State private var copied = false

    private var isInstalled: Bool {
        (sharedModel.apps + sharedModel.hiddenApps).contains { $0.appInfo.bundleIdentifier() == app.bundleIdentifier }
    }

    private var installedAppModel: LCAppModel? {
        (sharedModel.apps + sharedModel.hiddenApps).first(where: { $0.appInfo.bundleIdentifier() == app.bundleIdentifier })
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

    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: app.iconURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.25)
                }
            }
            .frame(width: 48, height: 48)
            // #15：圆角统一 12，跟顶部状态栏条/面板行同款（原来这里 10）
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 15)).bold()
                    .lineLimit(1)
                Text(metadataText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let downloadURL = app.latestVersion?.downloadURL {
                Button {
                    UIPasteboard.general.string = downloadURL.absoluteString
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(BasicButtonStyle())
            }
            Button {
                onDownload()
            } label: {
                Text("下载")
                    .font(.system(size: 13)).bold()
                    .foregroundColor(.white)
                    .frame(height: 30)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(BasicButtonStyle())
            .background(Capsule().fill(Color.gray))
            .clipShape(Capsule())
            if isPlugin && isPluginInstalled {
                Text("已安装")
                    .font(.system(size: 13)).bold()
                    .foregroundColor(.white)
                    .frame(height: 30)
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
                        .frame(height: 30)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(BasicButtonStyle())
                .background(Capsule().fill(Color.orange))
                .clipShape(Capsule())
            } else if !isPlugin && isInstalled {
                Button {
                    if let installedApp = installedAppModel {
                        Task { try? await installedApp.runApp() }
                    }
                } label: {
                    Text("打开")
                        .font(.system(size: 13)).bold()
                        .foregroundColor(.white)
                        .frame(height: 30)
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
                        .frame(height: 30)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(BasicButtonStyle())
                .background(Capsule().fill(Color.blue))
                .clipShape(Capsule())
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
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
                    fixedButton(systemImage: "chevron.down", tile: Color(.systemGray5), glyph: .primary, label: "收起") {
                        dockManager.toggleDockCollapse()
                        onSwitch()
                    }
                    Spacer()
                    fixedButton(systemImage: "rectangle.stack.badge.minus", tile: Color(.systemGray5), glyph: .primary, label: "最小化") {
                        dockManager.minimizeAllWindows()
                        onSwitch()
                    }
                    Spacer()
                    fixedButton(systemImage: "xmark", tile: Color.red.opacity(0.12), glyph: .red, label: "关闭全部") {
                        dockManager.closeAllWindows()
                        onSwitch()
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        fixedButton(systemImage: "chevron.down", tile: Color(.systemGray5), glyph: .primary, label: "收起") {
                            dockManager.toggleDockCollapse()
                            onSwitch()
                        }
                        fixedButton(systemImage: "rectangle.stack.badge.minus", tile: Color(.systemGray5), glyph: .primary, label: "最小化") {
                            dockManager.minimizeAllWindows()
                            onSwitch()
                        }
                        fixedButton(systemImage: "xmark", tile: Color.red.opacity(0.12), glyph: .red, label: "关闭全部") {
                            dockManager.closeAllWindows()
                            onSwitch()
                        }
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
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
@available(iOS 16.0, *)
private struct RunningAppIcon: View {
    let appInfo: LCAppInfo?
    @State private var icon: UIImage?

    var body: some View {
        Group {
            if let icon = icon {
                Image(uiImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.3))
            }
        }
        .onAppear {
            guard let appInfo = appInfo else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = appInfo.iconIsDarkIcon(false)
                DispatchQueue.main.async {
                    self.icon = loaded
                }
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
    
    var body: some View {
        HStack(spacing: 12) {
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
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // 次级动作统一中性灰胶囊（原来蓝/紫糖果色三件套太花，
            // 用户点名丑）；只有主动作「打开/启动」保留实心蓝
            Button(action: onMinimizeOpen) {
                Text("最小化")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            Button(action: onSmallWindowOpen) {
                Text("小窗口")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            // Launch button
            Button(action: onLaunch) {
                Text(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? "打开" : "启动")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        // 长按行：固定到面板顶部 / 取消固定（用户定）；
        // 正在运行的还多两个：重启（卡死时一步恢复）、关闭
        .contextMenu {
            Button {
                pinnedStore.toggle(app.appInfo.bundleIdentifier() ?? "")
            } label: {
                Label(pinnedStore.isPinned(app.appInfo.bundleIdentifier() ?? "") ? "取消固定" : "固定到顶部",
                      systemImage: pinnedStore.isPinned(app.appInfo.bundleIdentifier() ?? "") ? "pin.slash" : "pin")
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
    }
    
    private func loadIcon() {
        DispatchQueue.global(qos: .userInitiated).async {
            let icon = app.appInfo.iconIsDarkIcon(false)
            DispatchQueue.main.async {
                self.appIcon = icon
            }
        }
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
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
