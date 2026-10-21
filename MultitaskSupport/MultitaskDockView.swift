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
    // 手势面板覆盖层（背景遮罩 + 面板宿主）：只建一次常驻窗口待命，
    // 开/关只切可见性和位置；开没开以面板视图的 isHidden 为准，不以引用为准
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
    
    override init() {
        super.init()
        Self.deployDockGestureTweak()
        registerDockEdgeDarwinObservers()
        keyWindow!.rootViewController!.view.subviews.first!.addSubview(self.windowHostingView)
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
            if self.isVisible {
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
            self.apps.removeAll { $0.appUUID == appUUID }
            
            if self.apps.isEmpty {
                self.hideDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled() else { return }
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
                animateViewAppearance(targetView, from: center, in: window)
                return true
            }
        }
        
        return false
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
            
            if self.apps.count == 1 {
                self.showDock()
            } else if self.isVisible {
                self.updateDockFrame()
            }
        }
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
        // 不再要求 isVisible：源面板要在"没打开任何 App"时也能从主界面
        // 调出。其余每个动作入口都自带 isVisible/!apps.isEmpty 守卫，
        // 在主界面裸跑时各自落空，不会误触发显隐快捷栏或 App 面板。
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: gesture.view)
        let endX = gesture.location(in: gesture.view).x
        let width = gesture.view?.bounds.width ?? 0
        processGlobalSwipe(startEdge: globalSwipeStartEdge, translation: translation, endX: endX, width: width)
    }

    // 手势判定核心：宿主窗口手势与悬浮边条窗共用。
    // startEdge：0=任意位置 1=左边缘 2=右边缘；往外滑门槛低（手指很快滑出屏幕）。
    // 返回 true 表示本次判定触发了动作（边条 handler 据此做一次性触发）
    @discardableResult
    private func processGlobalSwipe(startEdge: Int, translation: CGPoint, endX: CGFloat, width: CGFloat) -> Bool {
        guard abs(translation.x) > 1.5 * abs(translation.y) else { return false }
        let draggingRight = translation.x > 0
        if startEdge == 2 {
            // 往右=隐藏（往外滑手指很快出屏，门槛10），往左=唤出（门槛24）
            if draggingRight {
                guard translation.x > 10 else { return false }
                fireDockAction { self.czfEdgeRightOutward() }
            } else {
                guard abs(translation.x) > 24 else { return false }
                fireDockAction { self.czfEdgeRightInward() }
            }
            return true
        } else if startEdge == 1 {
            // 往右=源面板（门槛30），往左=打开 App 面板（往外滑，门槛10）。
            // 原往右是唤出左侧快捷栏（czfEdgeLeftInward）：用户定左边缘
            // 往右改派源面板，与插件侧判定保持一致；门槛 30 与插件 pan
            // 路径对齐，只认边缘起手的决断横拖，不抢 App 自己的滑动。
            if draggingRight {
                guard translation.x > 30 else { return false }
                fireDockAction { self.czfOpenSourcesPanel() }
            } else {
                guard abs(translation.x) > 10 else { return false }
                fireDockAction { self.czfOpenAppPanel() }
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

    // 诊断标记：识别到合格拖动先轻震一下（宿主入口里还会再重震一下）
    private func fireDockAction(_ action: () -> Void) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }

    // 全部接收、只记录起手位置；触发判定在 handler 里按起手+落点做
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard globalSwipeRecognizers.contains(where: { $0 === gestureRecognizer }),
              let window = gestureRecognizer.view as? UIWindow else { return true }
        let x = touch.location(in: window).x
        if x >= window.bounds.width - 44 {
            globalSwipeStartEdge = 2
        } else if x <= 44 {
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

    // 诊断标记：游客回调到达宿主时震一下（在守卫之前，证明回调通了）
    private func edgeCallbackBuzz() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc public func czfEdgeRightInward() {
        edgeCallbackBuzz()
        guard isVisible || !apps.isEmpty, isDockHidden, dockIsOnRightSide else { return }
        showDockFromHidden()
    }

    @objc public func czfEdgeRightOutward() {
        edgeCallbackBuzz()
        guard isVisible || !apps.isEmpty, !isDockHidden, dockIsOnRightSide else { return }
        hideDockToSide()
    }

    @objc public func czfEdgeLeftInward() {
        edgeCallbackBuzz()
        guard isVisible || !apps.isEmpty, isDockHidden, !dockIsOnRightSide else { return }
        showDockFromHidden()
    }

    @objc public func czfEdgeLeftOutward() {
        edgeCallbackBuzz()
        guard isVisible || !apps.isEmpty, !isDockHidden, !dockIsOnRightSide else { return }
        hideDockToSide()
    }

    // 左边缘往左滑：打开 App 面板。面板独立呈现，不联动快捷栏——
    // 栏藏着就保持藏着（用户定：调面板时不许把栏也带出来）。
    // 2026-10-21 定案：左滑就是调面板，全屏同理，不用小窗口绕路
    //（#91 的先还原小窗口已删）。触发收不到的根因在插件侧（系统左
    // 边缘手势截走触摸），已由插件的 sendEvent 触摸漏斗修复。
    @objc public func czfOpenAppPanel() {
        edgeCallbackBuzz()
        guard isVisible || !apps.isEmpty else { return }
        presentAllAppsPanel()
    }

    // 左边缘往右滑：打开源面板（2026-10-21 用户定，与往左滑的 App
    // 面板对称）。故意不加 isVisible/!apps 守卫：没打开任何 App、在
    // 主界面时也要能调出（用户明确要求）；呈现走 keyWindow 兜底。
    @objc public func czfOpenSourcesPanel() {
        edgeCallbackBuzz()
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
        // 面板本体：底部 60% 高，上圆角
        let rootView = AnyView(
            AllAppsListView()
                .environmentObject(self)
                .environment(\.czfPanelClose) { [weak self] in self?.dismissPanelOverlay() }
        )
        let host = UIHostingController(rootView: rootView)
        let b = window.bounds
        host.view.frame = CGRect(x: 0, y: b.height, width: b.width, height: b.height * 0.6)
        host.view.layer.cornerRadius = 16
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
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
        host.view.layer.cornerRadius = 16
        host.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        host.view.clipsToBounds = true
        host.view.isHidden = true
        window.addSubview(host.view)
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
    private func registerDockEdgeDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let names = ["czf.dock.rightInward", "czf.dock.rightOutward", "czf.dock.leftInward", "czf.dock.leftOutward", "czf.dock.openPanel", "czf.dock.openSources"]
        for name in names {
            CFNotificationCenterAddObserver(center, observer, { _, observerPtr, cfName, _, _ in
                guard let observerPtr = observerPtr, let cfName = cfName else { return }
                let manager = Unmanaged<MultitaskDockManager>.fromOpaque(observerPtr).takeUnretainedValue()
                let notificationName = cfName.rawValue as String
                DispatchQueue.main.async {
                    switch notificationName {
                    case "czf.dock.rightInward": manager.czfEdgeRightInward()
                    case "czf.dock.rightOutward": manager.czfEdgeRightOutward()
                    case "czf.dock.leftInward": manager.czfEdgeLeftInward()
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
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "CZFDockGesture", withExtension: "dylib") else { return }
        // 必须比内容：旧版只比大小，同体积的不同构建被误判为已最新，
        // 插件改了却部署不出去（#91/#93 两次真机测试因此作废）。
        let srcData = try? Data(contentsOf: src)
        var copied = false
        for folder in [LCPath.tweakPath, LCPath.lcGroupTweakPath] {
            let dest = folder.appendingPathComponent("CZFDockGesture.dylib")
            let destData = try? Data(contentsOf: dest)
            if destData != srcData {
                try? fm.removeItem(at: dest)
                if (try? fm.copyItem(at: src, to: dest)) != nil {
                    copied = true
                }
            }
        }
        if copied {
            Task(priority: .userInitiated) {
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: true)
                try? await LCUtils.signTweaks(tweakFolderUrl: LCPath.lcGroupTweakPath, force: true)
            }
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
            keyWindow.addGestureRecognizer(leftEdgeGesture)
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
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
            // 左边缘往右滑改派源面板（用户定，与全局甩手判定一致）；
            // 右边缘照旧唤出快捷栏
            if gesture.edges == .left {
                czfOpenSourcesPanel()
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
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(isHidden ? 0.4 : 0.8),
                            Color.blue.opacity(isHidden ? 0.3 : 0.6)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
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
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(isHidden ? 0.2 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isHidden ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Collapse Button View
@available(iOS 16.0, *)
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)  
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "chevron.down")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)  
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Minimize All Button View
@available(iOS 16.0, *)
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.8))
                    .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
                
                Image(systemName: "apps.iphone")
                    .foregroundColor(.white)
                    .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Close All Button (red X)
@available(iOS 16.0, *)
struct CloseAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "xmark")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .bold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
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
        NavigationView {
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
                .padding()
            }
            .navigationTitle("App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { closePanel() }
                }
            }
            .searchable(text: .constant(""), prompt: "搜索")
        }
    }
    
    private func launchApp(_ app: LCAppModel) {
        let bundleId = app.appInfo.relativeBundlePath ?? ""
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == app.appInfo.dataUUID }) {
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            closePanel()
            return
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
            dockManager.minimizeWindow(uuid: runningApp.appUUID)
            closePanel()
            return
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
            let _ = dockManager.bringMultitaskViewToFront(uuid: runningApp.appUUID, from: nil)
            unmaximizeWindow(uuid: dataUUID)
            closePanel()
            return
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

// MARK: - Sources Panel View（左边缘往右滑调出，与 App 面板对称）
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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
                    Button("关闭") { closePanel() }
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
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
            
            // Minimize-open button
            Button(action: onMinimizeOpen) {
                Text("最小化")
                    .font(.subheadline)
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Small-window-open button
            Button(action: onSmallWindowOpen) {
                Text("小窗口")
                    .font(.subheadline)
                    .foregroundColor(.purple)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.purple.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Launch button
            Button(action: onLaunch) {
                Text(dockManager.apps.contains(where: { $0.appUUID == app.appInfo.dataUUID }) ? "打开" : "启动")
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
