//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Foundation
import SwiftUI
import UIKit
import Combine

struct LCAppBannerConfiguration {
    let model: LCAppModel
    let dynamicColors: Bool
    let darkModeIcon: Bool
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        
    private let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    private var configuration: LCAppBannerConfiguration
    private var exportTemporaryDirectory: URL?
    // dock 条目变化时重绘画片（卡片状态读 dock 存活态，不订阅
    // 的话只在模型变化时重绘、窗口开关后仍是旧态）。
    private var dockAppsCancellable: AnyCancellable?
    // 长按启动调面板的时间戳：长按后抬手会顺带触发一次
    // touchUpInside，1.5 秒内的这次点按要吞掉，否则长按
    // 又出面板又启动，面板会被盖住。
    private var runControlLongPressAt: Date?
    
    init(delegate: LCAppBannerDelegate, config: LCAppBannerConfiguration) {
        self.delegate = delegate
        self.configuration = config
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = bannerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        preferredContentSize = CGSize(width: 0, height: LCAppBannerRootView.bannerHeight)
        bannerView.runControl.addTarget(self, action: #selector(runButtonTapped), for: .touchUpInside)
        // 长按启动调手势面板（全部卡片通用）：边缘手势在客
        // App 里有时不灵，长按启动是宿主侧的可靠触发；点按
        // 仍是启动（大窗口）。行菜单已排除 runControl 区域，
        // 长按不会同时弹出行菜单。
        let runLongPress = UILongPressGestureRecognizer(target: self, action: #selector(runControlLongPressed(_:)))
        bannerView.runControl.addGestureRecognizer(runLongPress)
        // 面板同款次级按钮（16+ 才建，见 RootView；16 以下为 nil，不挂）。
        if #available(iOS 16.0, *) {
            bannerView.minimizeControl?.addTarget(self, action: #selector(minimizeButtonTapped), for: .touchUpInside)
            bannerView.smallWindowControl?.addTarget(self, action: #selector(smallWindowButtonTapped), for: .touchUpInside)
        }
        bannerView.addInteraction(UIContextMenuInteraction(delegate: self))

        // dock 变化（窗口开关）即重绘画片，卡片状态才跟得上；
        // 订阅即发一次当前值，多一次无害重绘。
        if #available(iOS 16.0, *) {
            dockAppsCancellable = MultitaskDockManager.shared.$apps
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshView() }
        }

        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(bannerDoubleTapped))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.cancelsTouchesInView = false
        bannerView.addGestureRecognizer(doubleTapGesture)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 卡片有时空白（3.8.280 修）：进多选时整列卡片重建，
        // 个别 representable 的 update 跑在了视图进层级之前，
        // 内容没落上去，之后又没任何事件再触发一次 refresh，
        // 行就一直空白（图标/名字/按钮全无，只剩勾选圈）。
        // 视图真正上屏时再刷一次 + 强行布局，自愈。
        refreshView()
        bannerView.setNeedsLayout()
        bannerView.layoutIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection == nil || traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refreshView()
        }
    }

    deinit {
        cleanupExportTemporaryDirectory()
    }

    func update(
        model: LCAppModel,
        dynamicColors: Bool,
        darkModeIcon: Bool
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon
        )
        refreshView()
        // 3.8.313：记一笔“待布局后重刷”（见 viewDidLayoutSubviews）。
        needsLayoutRefresh = true
    }

    // 3.8.313：3.8.280 的 viewDidAppear 自愈不够——List 里
    // representable 的 viewDidAppear 本就不可靠，个别 cell
    // 压根不走它，进多选时行还是空白（用户 19:12 真机：只剩
    // 红果一行有内容，其余只剩勾选圈）。layout 是比 appearance
    // 更可靠的信号：视图进了层级、拿到真实 frame 才会布局。
    // update 里先记一笔，布局时若框非空就重刷一次并清掉；
    // 只刷一次，不循环；viewDidAppear 的旧自愈留着当第二道。
    private var needsLayoutRefresh = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard needsLayoutRefresh else { return }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        needsLayoutRefresh = false
        refreshView()
        bannerView.setNeedsLayout()
        bannerView.layoutIfNeeded()
    }

    private func refreshView() {
        bannerView.update(
            model: configuration.model,
            appInfo: configuration.model.appInfo,
            dynamicColors: configuration.dynamicColors,
            darkModeIcon: configuration.darkModeIcon,
            traitCollection: traitCollection
        )
    }

    @objc private func bannerDoubleTapped(_ gestureRecognizer: UITapGestureRecognizer) {
        // 双击按钮区不进设置：原来只排除了启动 pill，两个新按钮
        // 同样排除（按钮是 bannerView 的直接子视图，frame 就是
        // bannerView 坐标系，不用逐个转坐标；16 以下新按钮为 nil，
        // 后两项恒为 false，行为与原来一致）。
        let location = gestureRecognizer.location(in: bannerView)
        guard !bannerView.runControl.frame.contains(location),
              !(bannerView.minimizeControl?.frame.contains(location) ?? false),
              !(bannerView.smallWindowControl?.frame.contains(location) ?? false) else {
            return
        }
        openSettings()
    }

    // 长按启动只调面板、不启动：.began 只发一次；抬手那下
    // 的 touchUpInside 由 runButtonTapped 里的时间戳吞掉。
    @objc private func runControlLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        if #available(iOS 16.0, *) {
            runControlLongPressAt = Date()
            MultitaskDockManager.shared.czfOpenAppPanel()
        }
    }

    // 启动偏好记忆（3.8.277 新3）：键 LCAppLastLaunchMode：
    // [唯一 ID: "large"/"small"/"minimized"]，存 App Group。
    // 小窗口/最小化按钮点时写；启动按钮不再读它——启动一律
    // 大窗口（用户亲定；3.8.277 让启动按记忆开，点过一次小
    // 窗后每次启动都开小窗，已废）。读函数已删，只留写。
    private static let lastLaunchModeKey = "LCAppLastLaunchMode"

    private enum LaunchMode: String {
        case large, small, minimized
    }

    private static func setLastLaunchMode(_ mode: LaunchMode, for model: LCAppModel) {
        guard let id = LCAppSortManager.shared.getUniqueIdentifier(for: model) else { return }
        var dict = LCUtils.appGroupUserDefault.dictionary(forKey: lastLaunchModeKey) as? [String: String] ?? [:]
        dict[id] = mode.rawValue
        LCUtils.appGroupUserDefault.set(dict, forKey: lastLaunchModeKey)
        LCDataManagementView.writeCZFSettingsBackupDebounced()
    }

    // O-3：锁屏守卫——runButtonTapped 带回路与 runApp / launchForAux 新起路
    // 共用：锁了且没解锁过就先人脸，通过返回 true；取消返回 false、抛错弹错
    // 返回 false，调用方直接 return。LCUtils.authenticateUser 成功后置
    // isHiddenAppUnlocked，后面 runApp 里的同款检查直接短路，不弹第二次人脸。
    private func czfAuthenticateIfLocked() async -> Bool {
        guard configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked else { return true }
        do {
            return try await LCUtils.authenticateUser()
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    // O-3：列表带回已在运行的 App（原 runButtonTapped 前半段原样抽出）：
    // dock 里有本条目、路径对得上就带回并拉满，返回 true，调用方直接 return；
    // 归属对不上不碰，返回 false 走 runApp 拆容器起新窗。认证不在这里做，
    // 调用方带回前先过 czfAuthenticateIfLocked。启动 = 大窗口（3.8.238
    // 重修：3.8.237 只在 isUsing 门内的带回路上拉满，门一关（isUsing 不同步、
    // 或归属不明）就落到 runApp 空转、窗还是小的；现改走面板同款 dock+
    // 路径归属路，isUsing 门不再拦——dock 条目本身就是窗口在跑的证据）。
    private func czfBringRunningAppToFront() -> Bool {
        if #available(iOS 16.0, *),
           let uuid = bannerInstanceUUID() {
            let dockManager = MultitaskDockManager.shared
            if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
                let belongsToOther: Bool
                if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                    belongsToOther = runningPath != configuration.model.appInfo.relativeBundlePath
                } else {
                    belongsToOther = true
                }
                if !belongsToOther {
                    var brought = false
                    if #available(iOS 16.1, *) {
                        brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                    }
                    if !brought {
                        brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                    }
                    // 带回成功拉满；带回失败但条目还在且不是本次
                    // C4 清掉的死窗（窗已在前台、只是 bring 没抬动）
                    // 同样拉满，别再静默空转回小窗。
                    let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
                    let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
                    if brought || (!cleanedByC4 && !entryGone) {
                        // maximizeWindow 是切换式，先判 !isMaximized，
                        // 否则已是最大窗会被反切回小窗。
                        if let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
                           !vc.isMaximized {
                            vc.maximizeWindow()
                        }
                        return true
                    }
                }
            } else {
                // 没有 dock 条目（原生窗口模式等）：保留旧行为，
                // 只带回不拉满（没 decorated VC 可拉），带回失败
                // 再落到 runApp。
                var brought = false
                if #available(iOS 16.1, *) {
                    brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
                }
                if !brought {
                    brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                }
                if brought {
                    return true
                }
            }
        }
        return false
    }

    @objc private func runButtonTapped() {
        if let pressedAt = runControlLongPressAt, Date().timeIntervalSince(pressedAt) < 1.5 {
            runControlLongPressAt = nil
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // O-3：带回前先认证（与 runApp 共用守卫 czfAuthenticateIfLocked）：
            // 原来带回成功直接 return，锁了的 App 正在运行时点启动直接
            // 看到内容，人脸一次都不弹。
            guard await self.czfAuthenticateIfLocked() else { return }
            // 带回是 UIKit 活，主线程上做；带回成功直接 return，不再新起。
            if await MainActor.run(body: { self.czfBringRunningAppToFront() }) { return }
            // 启动一律大窗口（用户亲定：启动=大窗，小窗口按钮=
            // 小窗，两按钮不得都开小窗）。3.8.277 新3 让启动按
            // 记忆开——上次点过小窗口/最小化，记忆就是 small/
            // minimized，下次点启动就跟着开小窗/最小化，正是本
            // 次回归。记忆只写不读，启动不再读它。
            // 已在跑的带回逻辑在上面已处理（return），到这里的
            // 都是要新起的；带回不记偏好，免得一次带回冲掉偏好。
            Self.setLastLaunchMode(.large, for: self.configuration.model)
            await self.runApp()
            // 新开路拉满（3.8.240）：App 没在跑时启动只管起新窗、
            // 起完没人拉满——上次关时是小窗就还是小窗，3.8.238
            // 只修了在跑的带回拉满。起完等新窗进 dock 再拉满一次，
            // 不管上次关时大小；小窗/最小化按钮不走这里。
            await MainActor.run {
                if #available(iOS 16.0, *) {
                    self.pollAndMaximizeFreshWindow()
                }
            }
        }
    }

    // 第 4 条（硬核优化 A 组）事件驱动拉满：窗口进 dock 即由
    // czfOnWindowAppeared 回调触发尝试，不再 0.1 秒×60 次轮询
    // 等它出现（上限仍为原来的 6 秒）。回调里 vc 未就绪、或拉
    // 满被动画重入守卫吞掉（isMaximized 没翻）时，才用 0.1 秒
    // 延迟链重试到 deadline。归属按路径验，别人的窗口占着
    // uuid 就停表不碰。启动失败已有 launch 侧 showError，
    // 这里到期不重复报错。
    // 返回 true = 已处理完（已拉满，或归属不对停表不再碰）。
    @available(iOS 16.0, *)
    private func czfTryMaximizeFreshWindow(uuid: String, expectedPath: String?) -> Bool {
        guard let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else { return false }
        let owned: Bool
        if let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty {
            owned = runningPath == expectedPath
        } else {
            owned = false
        }
        if !owned { return true }
        guard let vc = entry.view?._viewDelegate() as? DecoratedAppSceneViewController else { return false }
        if !vc.isMaximized {
            vc.maximizeWindow()
        }
        return vc.isMaximized
    }

    @available(iOS 16.0, *)
    private func czfRetryMaximizeFreshWindow(uuid: String, expectedPath: String?, deadline: Date) {
        guard !czfTryMaximizeFreshWindow(uuid: uuid, expectedPath: expectedPath) else { return }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.czfRetryMaximizeFreshWindow(uuid: uuid, expectedPath: expectedPath, deadline: deadline)
        }
    }

    // 容器还没建出来（uuid 为空）时等容器出现再注册窗口回调，
    // 上限 6 秒（原轮询同款预算）；等不到就停，不报错。
    @available(iOS 16.0, *)
    private func czfWaitUUIDThenMaximizeFreshWindow(deadline: Date, expectedPath: String?) {
        if let uuid = self.bannerInstanceUUID() {
            MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                self?.czfRetryMaximizeFreshWindow(uuid: uuid, expectedPath: expectedPath, deadline: deadline)
            }
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.czfWaitUUIDThenMaximizeFreshWindow(deadline: deadline, expectedPath: expectedPath)
        }
    }

    // 启动新开路拉满（3.8.240）：runApp 起完新窗可能还没进
    // dock（签名耗时），窗口出现由 czfOnWindowAppeared 回调
    // 触发拉满（见上）；uuid 为空（容器未建）时先等容器出现。
    @available(iOS 16.0, *)
    private func pollAndMaximizeFreshWindow() {
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        let deadline = Date().addingTimeInterval(6)
        guard let uuid = self.bannerInstanceUUID() else {
            czfWaitUUIDThenMaximizeFreshWindow(deadline: deadline, expectedPath: expectedPath)
            return
        }
        MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: 6) { [weak self] in
            self?.czfRetryMaximizeFreshWindow(uuid: uuid, expectedPath: expectedPath, deadline: deadline)
        }
    }

    private func runApp(multitask: Bool? = nil) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        do {
            try await configuration.model.runApp(multitask: multitask)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - 面板同款：最小化 / 小窗口（主列表卡片）
    // 面板行是 AppCardRow（LCAppModel）配三个闭包，本卡是 UIKit
    // banner，入口不同但语义照抄面板的 minimizeOpenApp /
    // smallWindowOpenApp：已在运行按实例 UUID 找 dock 条目、
    // 验相对路径归属；未运行先启动再最小化/还原小窗。
    // 实例 UUID 取选中容器的 folderName（与 runButtonTapped 的
    // currentDataFolder 同款），dataUUID 作回落。

    private func bannerInstanceUUID() -> String? {
        configuration.model.uiSelectedContainer?.folderName ?? configuration.model.appInfo.dataUUID
    }

    // 面板 private 的 unmaximizeWindow 同款（那边是 AllAppsListView
    // 私有方法，本卡调不到，照抄三行）：窗口已最大化时点一下
    // 还原成小窗；静态方法，不捕获 self，回调里可直接调。
    @available(iOS 16.0, *)
    private static func unmaximizeWindow(uuid: String) {
        guard let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
    }

    // 小窗口回落路专用（3.8.239）：czfOnWindowAppeared 是“同 uuid
    // 条目已存在就立即回调”、不验归属——同容器被别的条目占着时，
    // 回调会把别人的窗口还原成小窗。动作前再按路径复验一次，
    // 对不上/验不出就什么都不做，别动别人的窗口。
    @available(iOS 16.0, *)
    private static func unmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        unmaximizeWindow(uuid: uuid)
    }

    // 未运行分支的启动（含锁屏认证，与本卡 runApp 同款逻辑，
    // 只多一个 containerFolderName 参数，面板两路都带它；
    // 容器删光时传 nil，runApp 会重建容器，见 L14）。
    private func launchForAux(multitask: Bool?, containerFolderName: String?) async {
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                showError(error.localizedDescription)
                return
            }
        }
        do {
            try await configuration.model.runApp(multitask: multitask, containerFolderName: containerFolderName)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func minimizeButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
        // 新3：记偏好（启动不再读它，只写；启动一律大窗口）。
        // 记的是点的意图，启动失败也不改回。
        Self.setLastLaunchMode(.minimized, for: configuration.model)
        // 容器删光（L14）：先启动（runApp 会重建容器），容器一
        // 出现就重走正常路；60 次内没出现就停（启动失败已由
        // launch 侧 showError，不在这里重复报错）。
        guard let uuid = bannerInstanceUUID() else {
            Task { [weak self] in
                await self?.launchForAux(multitask: nil, containerFolderName: nil)
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.bannerInstanceUUID() != nil {
                    timer.invalidate()
                    self?.minimizeButtonTapped()
                } else if attempts >= 60 {
                    timer.invalidate()
                }
            }
            return
        }
        let dockManager = MultitaskDockManager.shared
        // 已在运行：归属对不上（共用容器的别的条目）不碰它，
        // 落到下面启动分支起自己的窗口；归属不明按启动/小窗口
        // 路同款视为别的条目（?? true），不再直接最小化。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther = runningApp.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 != configuration.model.appInfo.relativeBundlePath } ?? true
            if !belongsToOther {
                dockManager.minimizeWindow(uuid: uuid)
                return
            }
        }
        // 未运行：第 4 条——先注册窗口出现回调、再启动（小窗口路
        // C6 同款顺序），窗口出现即最小化；轮询只认归属对得上
        // 的条目，别人的窗口占着 uuid 时不碰它（自己的新窗若
        // 拆容器会换 uuid，等这个 uuid 也等不来）。上限 6 秒
        // （原轮询同款预算），超时未出现直接放弃、不报错。
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        dockManager.czfOnWindowAppeared(uuid: uuid, timeout: 6) {
            if let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) {
                let owned = entry.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 == expectedPath } ?? false
                if owned {
                    MultitaskDockManager.shared.minimizeWindow(uuid: uuid)
                }
            }
        }
        Task { [weak self] in
            await self?.launchForAux(multitask: nil, containerFolderName: uuid)
        }
    }

    @objc private func smallWindowButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
        // 新3：记偏好（启动不再读它，只写；启动一律大窗口）。
        // 记的是点的意图，启动失败也不改回。
        Self.setLastLaunchMode(.small, for: configuration.model)
        // O-3：小窗口按钮同款旁路——已在运行的带回并还原小窗会直接露出
        // 内容，原来不走认证。锁了先人脸，过了重进本函数（此时
        // isHiddenAppUnlocked 已置 true，不会重复弹；未运行分支走
        // launchForAux，里面也有同款认证）。
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            Task { [weak self] in
                guard let self else { return }
                if await self.czfAuthenticateIfLocked() {
                    await MainActor.run { self.smallWindowButtonTapped() }
                }
            }
            return
        }
        // 容器删光（L14）：先启动（runApp 会重建容器），容器一
        // 出现就重走正常路；60 次内没出现就停（启动失败已由
        // launch 侧 showError）。
        guard let uuid = bannerInstanceUUID() else {
            Task { [weak self] in
                await self?.launchForAux(multitask: true, containerFolderName: nil)
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.bannerInstanceUUID() != nil {
                    timer.invalidate()
                    self?.smallWindowButtonTapped()
                } else if attempts >= 60 {
                    timer.invalidate()
                }
            }
            return
        }
        let dockManager = MultitaskDockManager.shared
        // 已在运行：归属不明一律视为别的条目（面板同款），不顶
        // 窗口、直接落到启动分支；带回成功还原小窗，带回失败
        // 且条目不是本次清掉的死窗、也没消失时同样只还原不重起。
        if let runningApp = dockManager.apps.first(where: { $0.appUUID == uuid }) {
            let belongsToOther: Bool
            if let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty {
                belongsToOther = runningPath != configuration.model.appInfo.relativeBundlePath
            } else {
                belongsToOther = true
            }
            if !belongsToOther {
                let brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
                if brought {
                    Self.unmaximizeWindow(uuid: uuid)
                    return
                }
                let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
                let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
                if !cleanedByC4 && !entryGone {
                    Self.unmaximizeWindow(uuid: uuid)
                    return
                }
            }
        }
        // 未运行：先注册窗口出现回调、再启动（面板 C6 同款顺序），
        // 窗出来 0.35 秒后还原为小窗；30 秒未出现放弃，不留野观察者。
        // 回调动作前按路径复验归属（L5）：同 uuid 条目已存在时回调
        // 立即触发、不验归属——占着 uuid 的若是别人的窗口，复验
        // 拦住，别把别人的窗口还原成小窗。
        let expectedPath = configuration.model.appInfo.relativeBundlePath
        dockManager.czfOnWindowAppeared(uuid: uuid, timeout: 30) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Self.unmaximizeWindowIfOwned(uuid: uuid, expectedPath: expectedPath)
            }
        }
        Task { [weak self] in
            await self?.launchForAux(multitask: true, containerFolderName: uuid)
        }
    }

    private func makeContextMenu() -> UIMenu {
        let model = configuration.model
        let appInfo = model.appInfo
        var menuChildren: [UIMenuElement] = []

        // 1. Containers Picker (Equivalent to a Menu with single selection)
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { [weak self] container in
                UIAction(
                    title: container.name,
                    state: container == model.uiSelectedContainer ? .on : .off
                ) { _ in
                    // 只改 uiSelectedContainer 不持久：模型重载时选中会按
                    // dataUUID 重算回旧容器，等于白选。三个一起改，
                    // 选了哪个、启动就用哪个、重进还是哪个。
                    model.uiSelectedContainer = container
                    model.uiDefaultDataFolder = container.folderName
                    model.appInfo.dataUUID = container.folderName
                    self?.refreshView()
                }
            }
            menuChildren.append(UIMenu(title: "Containers", options: .displayInline, children: containerActions))
        }

        // 2. Main Section
        var sectionChildren: [UIMenuElement] = []
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.openDataFolder".loc,
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in
                self?.openDataFolder()
            })
        }

        // Multitask Toggle
        if #available(iOS 16.0, *) {
            let shouldLaunchInMultitaskMode = model.shouldLaunchInMultitaskMode
            sectionChildren.append(UIAction(
                title: shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                image: UIImage(systemName: shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus")
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.runApp(multitask: !shouldLaunchInMultitaskMode)
                }
            })
        }

        let addToHomeScreenMenu = UIMenu(
            title: "lc.appBanner.addToHomeScreen".loc,
            image: UIImage(systemName: "plus.app"),
            children: [
                UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.copyLaunchUrl()
                },
                UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.saveIcon()
                    }
                },
                UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { [weak self] _ in
                    Task { [weak self] in
                        await self?.createAppClip()
                    }
                }
            ]
        )
        sectionChildren.append(addToHomeScreenMenu)

        sectionChildren.append(UIAction(
            title: "lc.tabView.settings".loc,
            image: UIImage(systemName: "gear")
        ) { [weak self] _ in
            self?.openSettings()
        })

        // 3.8.431 设置低 #10：网格菜单有隐藏/锁定，列表菜单没有，
        // 两边补齐（调的都是 LCAppModel 已有方法，与网格同款）。
        sectionChildren.append(UIAction(
            title: appInfo.isHidden ? "恢复显示" : "隐藏",
            image: UIImage(systemName: appInfo.isHidden ? "eye" : "eye.slash")
        ) { _ in
            Task { await model.toggleHidden() }
        })
        sectionChildren.append(UIAction(
            title: appInfo.isLocked ? "解锁" : "锁定",
            image: UIImage(systemName: appInfo.isLocked ? "lock.open" : "lock")
        ) { _ in
            Task { await model.setLocked(newLockState: !appInfo.isLocked) }
        })

        // 单 App VPN（用户定）：长按直接调用，不用进设置页翻。
        // 没开过 → 打标记并立刻打开这个 App（插件在启动签名时
        // 自动部署、核心自动起）；已开 → 摘标记（残留插件下次
        // 启动时自动清掉，与设置页开关同一套逻辑）
        let vpnEnabled = CZFVPNManager.isEnabled(for: appInfo)
        sectionChildren.append(UIAction(
            title: vpnEnabled ? "关闭 VPN 打开" : "用 VPN 打开",
            image: UIImage(systemName: "globe")
        ) { [weak self] _ in
            if vpnEnabled {
                CZFVPNManager.setEnabled(false, for: appInfo)
            } else {
                CZFVPNManager.setEnabled(true, for: appInfo)
                Task { [weak self] in
                    await self?.runApp()
                }
            }
        })

        // Tweak/Module Picker（多选：点一下勾上/再点取消，
        // 可同时选多个模块文件夹，启动时逐个加载；「无」清空）
        let selectedFolders = LCAppModel.czfSplitTweakFolders(model.uiTweakFolder)
        var tweakMenuActions: [UIAction] = [
            UIAction(
                title: "lc.common.none".loc,
                state: selectedFolders.isEmpty ? .on : .off
            ) { _ in
                model.uiTweakFolder = nil
            }
        ]
        tweakMenuActions += DataManager.shared.model.tweakFolderNames.map { folderName in
            UIAction(
                title: folderName,
                state: selectedFolders.contains(folderName) ? .on : .off
            ) { _ in
                model.toggleTweakFolder(folderName)
            }
        }
        sectionChildren.append(UIMenu(
            title: "lc.appSettings.tweakFolder".loc,
            image: UIImage(systemName: "wrench.and.screwdriver"),
            children: tweakMenuActions
        ))

        if !model.uiIsShared {
            sectionChildren.append(UIAction(
                title: "lc.appBanner.uninstall".loc,
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.uninstall()
                }
            })
        }

        menuChildren.append(UIMenu(
            title: appInfo.relativeBundlePath ?? "",
            options: .displayInline,
            children: sectionChildren
        ))
        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    private func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: configuration.model)))
    }

    private func openDataFolder() {
        // 容器名含空格时 URL(string:) 直接返回 nil；先 percent-encoding 再拼
        //（与容器设置页同款），拼不出弹提示而不是静默 return。
        guard let folderName = configuration.model.uiSelectedContainer?.folderName,
              let encodedName = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(encodedName)") else {
            let alert = UIAlertController(title: nil, message: "无法打开数据文件夹", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default))
            present(alert, animated: true)
            return
        }
        UIApplication.shared.open(url)
    }

    // 新4（3.8.277）：删 App 的文件部分（不含确认弹窗）：删 .app
    // 包、从列表移除、可选删数据容器 + 钥匙串。单个 uninstall()
    // 与批量删除共用这一份，不另写。删包失败直接 throw（App 还
    // 在列表里）；容器单个删失败记下来继续，不中断整批。
    // removeFromList 由调用方传：单个走 delegate.removeApp，
    // 批量走列表自己的 removeApp（同一个方法）。返回删失败的容器名。
    static func deleteAppFiles(_ model: LCAppModel, removeDataFolders: Bool, removeFromList: (LCAppModel) -> Void) throws -> [String] {
        let appInfo = model.appInfo
        guard let bundlePath = appInfo.bundlePath() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fileManager = FileManager.default
        try fileManager.removeItem(atPath: bundlePath)
        removeFromList(model)
        guard removeDataFolders else { return [] }
        var failedContainers: [String] = []
        for container in appInfo.containers {
            let dataUUID = container.folderName
            do {
                try fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
            } catch {
                failedContainers.append(dataUUID)
                continue
            }
            LCUtils.removeAppKeychain(dataUUID: dataUUID)
            DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
        }
        return failedContainers
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        let displayName = appInfo.displayName() ?? configuration.model.displayName
        let shouldUninstall = await presentConfirmation(
            title: "lc.appBanner.confirmUninstallTitle".loc,
            message: "lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(displayName),
            confirmTitle: "lc.appBanner.uninstall".loc,
            cancelTitle: "lc.common.cancel".loc
        )
        guard shouldUninstall == true else {
            return
        }

        var shouldRemoveAppFolders = false
        let containers = appInfo.containers
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            let failedContainers = try Self.deleteAppFiles(configuration.model, removeDataFolders: shouldRemoveAppFolders) { [weak self] model in
                self?.delegate.removeApp(app: model)
            }
            if !failedContainers.isEmpty {
                showError("以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
            }
        } catch {
            showError(error.localizedDescription)
        }
    }



    private func copyLaunchUrl() {
        guard let relativeBundlePath = configuration.model.appInfo.relativeBundlePath else {
            return
        }

        // 文件夹名/容器名可能含空格，直接拼出的链接粘贴后打不开；先编码。
        let encodedBundlePath = relativeBundlePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativeBundlePath
        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderName
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)&container-folder-name=\(encodedFolder)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)"
        }
    }

    private func createAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let profile = configuration.model.appInfo.generateWebClipConfig(
                withContainerId: configuration.model.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let rawDisplayName = configuration.model.appInfo.displayName() ?? configuration.model.displayName
            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                cleanupExportTemporaryDirectory()
                return
            }

            let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            documentPicker.delegate = self
            documentPicker.presentationController?.delegate = self
            present(documentPicker, animated: true)
        } catch {
            cleanupExportTemporaryDirectory()
            showError(error.localizedDescription)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        cleanupExportTemporaryDirectory()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        cleanupExportTemporaryDirectory()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanupExportTemporaryDirectory()
    }

    private func cleanupExportTemporaryDirectory() {
        guard let exportTemporaryDirectory else {
            return
        }
        try? FileManager.default.removeItem(at: exportTemporaryDirectory)
        self.exportTemporaryDirectory = nil
    }
}
