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
    // F1（3.8.635）：签名剩余天数（nil = 没读到，不显示）。
    let expiryDaysLeft: Int?
}


final class LCAppBannerViewController: UIViewController, UIContextMenuInteractionDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        
    private let delegate: LCAppBannerDelegate
    private let bannerView = LCAppBannerRootView()
    private var configuration: LCAppBannerConfiguration
    private var exportTemporaryDirectory: URL?
    // 3.8.684（B1）：批量模式——批量态下长按菜单与长按启动双双
    // 设防；由 LCAppBanner 下行，控制器不自己猜。
    var czfBatchMode = false
    // 3.8.647（F3）：导出 IPA 进行中标志——防重入（菜单标题同步显示“正在导出…”）。
    private var czfExporting = false
    // dock 条目变化时重绘画片（卡片状态读 dock 存活态，不订阅
    // 的话只在模型变化时重绘、窗口开关后仍是旧态）。
    private var dockAppsCancellable: AnyCancellable?
    // 长按启动调面板的时间戳：长按后抬手会顺带触发一次
    // touchUpInside，1.5 秒内的这次点按要吞掉，否则长按
    // 又出面板又启动，面板会被盖住。
    private var runControlLongPressAt: Date?

    // P0 hitTest 诊断（3.8.678）：只读诊断口，不改行为。
    // 命中 banner 行时，观察器经响应链读本卡的 bundle id。
    var czfDiagnosticBundleID: String? { configuration.model.appInfo.bundleIdentifier() }

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
        darkModeIcon: Bool,
        // F1（3.8.635）：签名剩余天数（nil = 没读到，不显示）。
        expiryDaysLeft: Int? = nil
    ) {
        loadViewIfNeeded()
        configuration = LCAppBannerConfiguration(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            expiryDaysLeft: expiryDaysLeft
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
            traitCollection: traitCollection,
            expiryDaysLeft: configuration.expiryDaysLeft
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
        // 3.8.684（B1）：批量态下长按启动不开多任务面板——点按已
        // 改勾选，长按再开面板与批量语义冲突。
        guard !czfBatchMode else { return }
        if #available(iOS 16.0, *) {
            runControlLongPressAt = Date()
            MultitaskDockManager.shared.czfOpenAppPanel()
        }
    }

    // 启动偏好记忆已删（F-5）：3.8.277 新3 的 LCAppLastLaunchMode
    // 全仓零读者（读函数早已删，只剩写），每次启动/最小化/小窗口
    // 点按都写一次字典 + 触发一次设置备份，白白 churn；启动一律
    // 大窗口是用户亲定的，不读记忆。写函数与备份键表里那一项已删。

    // O-3：锁屏守卫——runButtonTapped 带回路与 runApp / launchForAux 新起路
    // 共用：锁了且没解锁过就先人脸，通过返回 true；取消返回 false、抛错弹错
    // 返回 false，调用方直接 return。LCUtils.authenticateUser 成功后置
    // isHiddenAppUnlocked，后面 runApp 里的同款检查直接短路，不弹第二次人脸。
    private func czfAuthenticateIfLocked() async -> Bool {
        // 3.8.573（L104）：本函数在四个裸 Task 里调（启动/最小化/
        // 小窗口/设置），isLocked 读 _info（LCAppInfo.m:698）、
        // isHiddenAppUnlocked 是 @Published（Shared.swift:123），
        // 离主线程读是 L69/L70 同款——L74 只修了 LCAppModel 那份
        // 共用守卫，本卡这份自写谓词漏了。一点取齐再判（同款形状）。
        let (locked, unlocked) = await MainActor.run { (configuration.model.appInfo.isLocked, DataManager.shared.model.isHiddenAppUnlocked) }
        guard locked && !unlocked else { return true }
        do {
            return try await LCUtils.authenticateUser()
        } catch {
            showError(error.localizedDescription)
            return false
        }
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
            // F-4：带回走共用助手（LCAppModel，banner/网格/面板三处共用）。
            if await MainActor.run(body: { LCAppModel.czfBringRunningAppToFront(self.configuration.model, maximize: true) }) { return }
            // 启动一律大窗口（用户亲定：启动=大窗，小窗口按钮=
            // 小窗，两按钮不得都开小窗）。3.8.277 新3 的启动偏好
            // 记忆（LCAppLastLaunchMode）已删——全仓零读者，只写
            // 不读（F-5）；带回不记偏好。
            // 已在跑的带回逻辑在上面已处理（return），到这里的
            // 都是要新起的。
            await self.runApp()
            // 新开路拉满（3.8.240）：App 没在跑时启动只管起新窗、
            // 起完没人拉满——上次关时是小窗就还是小窗，3.8.238
            // 只修了在跑的带回拉满。起完等新窗进 dock 再拉满一次，
            // 不管上次关时大小；小窗/最小化按钮不走这里。
            await MainActor.run {
                if #available(iOS 16.0, *) {
                    // F-4：起完拉满走共用助手（LCAppModel，banner/网格/面板三处共用）。
                    LCAppModel.czfPollAndMaximizeFreshWindow(app: self.configuration.model)
                }
            }
        }
    }

    private func runApp(multitask: Bool? = nil) async {
        // 3.8.573（L104）：原来这里自写一份同款认证内联判据，离主
        // 线程读 isLocked/_info 与 isHiddenAppUnlocked（L69/L70
        // 同款）；与上面共用守卫语义一字不差，走它。
        guard await self.czfAuthenticateIfLocked() else { return }

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
    // F-4/F-10：实例 UUID、带回、拉满、还原小窗、最小化/小窗口
    // 全走 LCAppModel 的共用助手（banner/网格/面板三处共用），
    // 本卡只留按钮接线与认证、记偏好、容器删光重进三件本卡事。
    // 实例 UUID = 选中容器 folderName 优先、dataUUID 回落
    // （LCAppModel.czfInstanceUUID）。

    // 未运行分支的启动（含锁屏认证，与本卡 runApp 同款逻辑，
    // 只多一个 containerFolderName 参数，面板两路都带它；
    // 容器删光时传 nil，runApp 会重建容器，见 L14）。
    private func launchForAux(multitask: Bool?, containerFolderName: String?) async {
        // 3.8.573（L104）：同 runApp，自写内联判据离主线程读
        // isLocked/_info 与 isHiddenAppUnlocked；走共用守卫。
        guard await self.czfAuthenticateIfLocked() else { return }
        do {
            try await configuration.model.runApp(multitask: multitask, containerFolderName: containerFolderName)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func minimizeButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
        // 容器删光（L14）：先启动（runApp 会重建容器），容器一
        // 出现就重走正常路；60 次内没出现就停（启动失败已由
        // launch 侧 showError，不在这里重复报错）。
        guard configuration.model.czfInstanceUUID != nil else {
            Task { [weak self] in
                await self?.launchForAux(multitask: true, containerFolderName: nil) // 3.8.900（L585-B1）：最小化打开必须走多任务窗——容器重建这一步经典交接同样杀宿主，重进 minimizeButtonTapped 的定时器随宿主一起死，最小化永不发生。小窗口路同款已传 true（Banner:331）。
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.configuration.model.czfInstanceUUID != nil {
                    timer.invalidate()
                    self?.minimizeButtonTapped()
                } else if attempts >= 60 {
                    timer.invalidate()
                }
            }
            return
        }
        // F-10：运行中分支不要认证（最小化不露内容）：先试，成了
        // 直接回；未运行才要认证（小窗口路同款重进，过了重进本函数，
        // 此时 isHiddenAppUnlocked 已置，不重复弹）。
        if LCAppModel.czfMinimizeRunningWindow(configuration.model) { return }
        if configuration.model.appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            Task { [weak self] in
                guard let self else { return }
                if await self.czfAuthenticateIfLocked() {
                    await MainActor.run { self.minimizeButtonTapped() }
                }
            }
            return
        }
        // F-10：最小化走共用助手（LCAppModel，banner/面板共用）；
        // 未运行分支启动完重读 uuid、换号重等（F-3），6 秒超时报一次。
        Task { [weak self] in
            guard let self else { return }
            await LCAppModel.czfMinimizeApp(self.configuration.model, onError: { [weak self] msg in
                self?.showError(msg)
            })
        }
    }

    @objc private func smallWindowButtonTapped() {
        guard #available(iOS 16.0, *) else { return }
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
        guard configuration.model.czfInstanceUUID != nil else {
            Task { [weak self] in
                await self?.launchForAux(multitask: true, containerFolderName: nil)
            }
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                attempts += 1
                if self?.configuration.model.czfInstanceUUID != nil {
                    timer.invalidate()
                    self?.smallWindowButtonTapped()
                } else if attempts >= 60 {
                    timer.invalidate()
                }
            }
            return
        }
        // F-10：小窗口走共用助手（LCAppModel，banner/面板共用）；
        // 未运行分支启动完重读 uuid、换号重等（F-3），30 秒超时报一次。
        Task { [weak self] in
            guard let self else { return }
            await LCAppModel.czfSmallWindowApp(self.configuration.model, onError: { [weak self] msg in
                self?.showError(msg)
            })
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

        // 3.8.639（F3）：复制 Bundle ID——排续签/双图标问题时常要报
        // Bundle ID，原来只能进设置页长按选中信息区那行文本复制；
        // 标题硬编码中文，沿用本菜单“隐藏/锁定/恢复显示”硬编码先例。
        sectionChildren.append(UIAction(
            title: "复制 Bundle ID",
            image: UIImage(systemName: "doc.on.doc")
        ) { _ in
            UIPasteboard.general.string = appInfo.bundleIdentifier() ?? ""
        })

        // 3.8.647（F2）：复制版本号——与“复制 Bundle ID”同款硬编码中文；
        // version 是 "?"（读不到）时不显示，照抄版本行 app.version == "?" 的判法。
        if model.version != "?" {
            sectionChildren.append(UIAction(
                title: "复制版本号",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = model.version
            })
        }

        // 3.8.647（F3）：导出 IPA——3.8.645 只进了网格菜单，列表模式
        // 长按没有导出；与网格菜单对齐，标题硬编码中文，同“复制
        // Bundle ID”先例；导出中显示“正在导出…”、防重入。
        sectionChildren.append(UIAction(
            title: czfExporting ? "正在导出…" : "导出 IPA",
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.czfExportIPA()
        })

        // 3.8.682（F1）：备份这个 App——单项进批量备份范围单（复用
        // batchBackup：人脸门、busy 标志与回执全在那路）；标题硬编码
        // 中文，同“复制 Bundle ID”先例。
        sectionChildren.append(UIAction(
            title: "备份这个 App",
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
            self?.delegate.backupApp(app: model)
        })

        // 3.8.641（F1）：置顶/取消置顶——与网格菜单同款（列表置顶键，
        // 与坞固定区无关）；标题硬编码中文，同“复制 Bundle ID”先例。
        sectionChildren.append(UIAction(
            title: CZFListPinnedStore.shared.isPinned(model) ? "取消置顶" : "置顶",
            image: UIImage(systemName: CZFListPinnedStore.shared.isPinned(model) ? "pin.fill" : "pin")
        ) { _ in
            CZFListPinnedStore.shared.toggle(model)
            LCAppSortManager.shared.czfResortAfterPinChange()
        })

        // 3.8.700（F1）：固定到面板/取消固定——与“置顶”不同：置顶是
        // 列表内排前（CZFListPinnedStore），固定是进坞固定区
        //（CZFPinnedAppsStore，坞面板行菜单/源页菜单同款）；文案
        // 按固定态翻，协调员定“固定到面板”。标题硬编码中文，同先例。
        sectionChildren.append(UIAction(
            title: CZFPinnedAppsStore.shared.isPinned(model) ? "取消固定" : "固定到面板",
            image: UIImage(systemName: CZFPinnedAppsStore.shared.isPinned(model) ? "pin.slash" : "pin")
        ) { _ in
            CZFPinnedAppsStore.shared.toggle(model)
        })

        // 3.8.702（F2）：忽略此版本 / 取消忽略更新——网格菜单同款，
        // UIKit 版；最新版从源页写的 CZFUpdatableLatestVersions 字典
        // 取（归一 ID → 版本|build），写键用归一 Bundle ID，与
        // computeUpdatableApps 的读键（源原始包名）同一口径；写完发
        // CZFRecomputeUpdatableCache 只重算不联网。批量态设防现成：
        // contextMenuInteraction 批量态直接 return nil，不另写门。
        let czfNormalizedID = czfNormalizedBundleID(appInfo.bundleIdentifier() ?? "")
        let czfLatestDict = CZFUpdateIgnore.latestVersionDict(from: UserDefaults.standard.string(forKey: "CZFUpdatableLatestVersions") ?? "")
        let czfHasUpdate = Set((UserDefaults.standard.string(forKey: "CZFUpdatableBundleIDs") ?? "").split(separator: ",").map(String.init)).contains(czfNormalizedID)
        if czfHasUpdate, let czfLatestKey = czfLatestDict[czfNormalizedID] {
            sectionChildren.append(UIAction(
                title: "忽略此版本",
                image: UIImage(systemName: "bell.slash")
            ) { _ in
                CZFUpdateIgnore.setIgnored(czfLatestKey, for: czfNormalizedID)
                NotificationCenter.default.post(name: Notification.Name("CZFRecomputeUpdatableCache"), object: nil)
            })
        }
        if let czfLatestKey = czfLatestDict[czfNormalizedID],
           let czfStored = CZFUpdateIgnore.ignoredVersion(for: czfNormalizedID) {
            let czfSplit = CZFUpdateIgnore.splitIgnoredKey(czfLatestKey)
            if CZFUpdateIgnore.isIgnoredStored(czfStored, version: czfSplit.version, build: czfSplit.build) {
                sectionChildren.append(UIAction(
                    title: "取消忽略更新",
                    image: UIImage(systemName: "bell")
                ) { _ in
                    CZFUpdateIgnore.setIgnored(nil, for: czfNormalizedID)
                    NotificationCenter.default.post(name: Notification.Name("CZFRecomputeUpdatableCache"), object: nil)
                })
            }
        }

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
            // 3.8.556（L233）：!appInfo.isLocked 在裸 Task 里算就是离主线程读 _info（LCAppInfo.m:714）；主线程 setLocked 写 _info + save 时读-写并发可能崩（L70/L72/L74 同款，L74 只修了 setLocked 本体入口、没修这两路调用方传参时的读）。整段放主 actor 上算。
            Task { @MainActor in await model.setLocked(newLockState: !appInfo.isLocked) }
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

        menuChildren.append(UIMenu(
            title: appInfo.relativeBundlePath ?? "",
            options: .displayInline,
            children: sectionChildren
        ))

        // 3.8.647（UI 打磨）：卸载是唯一的 destructive 项，单独成组
        //（网格菜单 3.8.645 同款分隔线），与普通项之间隔一条分隔线，误删少一点。
        if !model.uiIsShared {
            menuChildren.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(
                    title: "lc.appBanner.uninstall".loc,
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    Task { [weak self] in
                        await self?.uninstall()
                    }
                }
            ]))
        }

        return UIMenu(title: "", children: menuChildren)
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        // 3.8.684（B1）：批量态下不弹长按菜单——与网格模式同款
        // （CZFAppGridView 低 #9：批量态下不挂 contextMenu）；
        // 否则卸载/隐藏/锁定/“备份这个 App”全能点，“备份这个
        // App”还会把已选多项无声替换成 1 项。
        guard !czfBatchMode else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.makeContextMenu()
        }
    }

    private func openSettings() {
        // F-9：锁定 App 的设置页进前先认证（与启动同款守卫）；
        // 双击与菜单都走这里，一处守住两路；未通过不打开
        //（认证失败时 czfAuthenticateIfLocked 已弹错）。
        Task { [weak self] in
            guard let self else { return }
            guard await self.czfAuthenticateIfLocked() else { return }
            // 3.8.511（L33）：裸 Task 不在主 actor 上，openNavigationView
            // 写 @State（navigateTo/isNavigationActive），必须回主线
            // 程，否则设置页可能打不开、还报 Publishing changes from
            // background threads（L32 toggleHidden 同款）。
            await MainActor.run {
                self.delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: self.configuration.model)))
            }
        }
    }

    private func openDataFolder() {
        // 3.8.900（L572-5）：外置容器（选中容器带 storageBookMark）的数据不住在
        // dataPath 下，原来无条件拼 shareddocuments://dataPath/<夹名>，文件 App
        // 打开的是不存在的本地路径（容器设置页 LCContainerView 同款已修）。外置
        // 容器直接开解析出的 URL（D:7322 外部备份文件夹同款）；书签已死时弹现有
        // 提示，不开错路。本地容器走下面原路。
        if let selected = configuration.model.uiSelectedContainer, selected.storageBookMark != nil {
            if selected.bookmarkResolved, let resolvedURL = selected.resolvedContainerURL {
                UIApplication.shared.open(resolvedURL)
            } else {
                let alert = UIAlertController(title: nil, message: "无法打开数据文件夹", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "确定", style: .default))
                present(alert, animated: true)
            }
            return
        }
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
    // 3.8.900（L566-5）：删文件放后台——原来三路调用都在主线程同步删
    // .app 包 + 全部数据容器 + 备份，大 App 数 GB 小文件、主线程冻住
    // 数秒、无进度（网格单删确认框按钮同步调、横幅卡 uninstall 包进
    // MainActor.run、批量每项各 await 一次也只在项与项之间让出主线程，
    // 单项内照样冻住）。_info 读（bundlePath/containers/dataUUID）与
    // @Published 写（removeFromList/appDataFolderNames）仍在主线程做，
    // 只有 removeItem + SecItem 清钥匙串（线程安全）放 detached 后台；
    // 顺序与原来一致（先删包、再从列表移除、再删容器与备份）。
    static func deleteAppFiles(_ model: LCAppModel, removeDataFolders: Bool, removeFromList: (LCAppModel) -> Void) async throws -> (failedContainers: [String], keptBackupName: String?) {
        let appInfo = model.appInfo
        // 快照（主线程，L307-1 口径）：_info 读 + 备份文件夹名配对都在这里取齐，
        // 后台只用快照里的值，不再碰 _info；容器快照取的是值（夹名/路径/组号/
        // 有无书签），不留 LCContainer 对象过 await。
        struct CZFDeleteContainer {
            let folderName: String
            let containerURL: URL
            let keychainGroupId: Int
            let hasBookmark: Bool
        }
        struct CZFDeletePlan {
            let bundlePath: String
            let containers: [CZFDeleteContainer]
            let dataUUID: String?
            let backupFolderName: String?
            let backupRoot: URL?
        }
        let plan: CZFDeletePlan = try await MainActor.run {
            // 3.8.900（L569-7）：正在运行的 App 不许删——三路删除（网格单删/
            // 横幅卸载/批量删除）全走本函数，删前谁都不查在用：包与数据容器
            // 当场删掉，窗口里跑着的客 App 下次读资源/写数据就崩或丢数据，
            // “删除 App 及其数据”还会把运行中 App 的容器也一并删掉。
            // 覆盖安装（L428#9）与删容器（LCContainerView）都有在用拦截，
            // 删 App 这路漏了。isAppRunning 盖宿主侧启动/签名窗口（含多任
            // 务 runApp 路）；容器锁盖别个 LC 宿主的窗口（锁文件记 audit
            // token、csops 验进程活着，死进程不误拦）。删之前拦住、一个
            // 文件都不动；三路调用方原有 catch 已会把抛出的错弹出来
            // （网格 czfGridError、横幅 showError、批量失败清单）。
            if model.isAppRunning {
                throw "这个 App 正在运行，先退出它再删除"
            }
            for c in appInfo.containers {
                if LCSharedUtils.getContainerUsingLCScheme(withFolderName: c.folderName) != nil {
                    throw "这个 App 正在运行，先退出它再删除"
                }
            }
            guard let bundlePath = appInfo.bundlePath() else {
                throw CocoaError(.fileNoSuchFile)
            }
            var backupFolderName: String? = nil
            var backupRoot: URL? = nil
            if removeDataFolders,
               let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let root = docsURL.appendingPathComponent("Backups")
                backupRoot = root
                backupFolderName = LCDataManagementView.backupFolderName(for: model, backupRoot: root, fm: FileManager.default)
            }
            return CZFDeletePlan(
                bundlePath: bundlePath,
                containers: appInfo.containers.map { CZFDeleteContainer(folderName: $0.folderName, containerURL: $0.containerURL, keychainGroupId: $0.keychainGroupId, hasBookmark: $0.storageBookMark != nil) },
                dataUUID: appInfo.dataUUID,
                backupFolderName: backupFolderName,
                backupRoot: backupRoot
            )
        }
        // 删包（后台）：失败直接 throw，App 还在列表里（与原来一致，
        // removeFromList 还没调）。
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(atPath: plan.bundlePath)
        }.value
        await MainActor.run { removeFromList(model) }
        guard removeDataFolders else { return ([], nil) }
        // 删容器与备份（后台）：容器单个删失败记下来继续，不中断整批；
        // 钥匙串是 SecItem、线程安全；删掉的夹名攒起来，最后回主线程
        // 一次清 appDataFolderNames。
        let deletedResult = await Task.detached(priority: .userInitiated) {
            var failedContainers: [String] = []
            var deletedUUIDs: [String] = []
            for container in plan.containers {
                // 3.8.577（L381-1）：删容器不能硬拼 dataPath——共享夹（isShared，LCContainer.swift:433 全按 appInfo.isShared 建）住在 lcGroupDataPath（createFolder :987、moveToAppGroup :1196、恢复 D:5664 同款），dataPath 里根本没有；原来每删一个带数据的共享 App 都报“以下容器删除失败，已保留”，其实一个没删、共享数据还以孤儿形态烂在 App Group 里（D 的悬空清理只扫 dataPath，永远扫不到它），钥匙串也没清。按 containerURL 删（isShared 走共享根、私人走 dataPath，D 全仓同款；私人夹算出的路径与原来一字不差）；书签外置夹（storageBookMark）是用户自管的外置文件夹、搬移两路也跳过它，不删、不报错。
                if container.hasBookmark {
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: container.containerURL)
                } catch {
                    failedContainers.append(container.folderName)
                    continue
                }
                LCUtils.removeAppKeychain(dataUUID: container.folderName, keychainGroupId: container.keychainGroupId)
                deletedUUIDs.append(container.folderName)
            }
            // 删 App 及其数据时清本地备份（用户定）：锁了的留着，
            // 没锁的才删。只认 manifest dataUUID 对得上的那一个
            // 文件夹（同实例），认不出/对不上就不删，绝不删错
            // 别人的备份。本地与 iCloud 同名共用一把锁，两边同
            // 删同留（只删本地的话 iCloud 那份下次刷新又冒出来，
            // 见 deleteBackup 3.8.306）。
            var keptBackupName: String? = nil
            if let folderName = plan.backupFolderName, let root = plan.backupRoot {
                let folderURL = root.appendingPathComponent(folderName)
                if FileManager.default.fileExists(atPath: folderURL.path),
                   let info = LCDataManagementView.manifestInfo(of: folderURL),
                   let myUUID = plan.dataUUID, !myUUID.isEmpty,
                   info.dataUUID == myUUID {
                    if LCDataManagementView.isBackupLocked(folderName) {
                        keptBackupName = folderName
                    } else {
                        try? FileManager.default.removeItem(at: folderURL)
                        if let externalRoot = LCDataManagementView.externalBackupFolderURL() {
                            try? FileManager.default.removeItem(at: externalRoot.appendingPathComponent(folderName))
                        }
                    }
                }
            }
            return (failedContainers, deletedUUIDs, keptBackupName)
        }.value
        await MainActor.run {
            for uuid in deletedResult.1 {
                DataManager.shared.model.appDataFolderNames.removeAll { $0 == uuid }
            }
        }
        return (deletedResult.0, deletedResult.2)
    }

    private func uninstall() async {
        let appInfo = configuration.model.appInfo
        // 3.8.558（L307-1）：displayName() 读 _info（LCAppInfo.m:188），containers 读 _info[@"LCContainers"]（LCAppInfo.m:939）；本函数从横幅卡 UIAction 的裸 Task 调来、不在主线程（L33 同款，见 presentConfirmation 注释；L303-2 只修了 saveIcon/createAppClip，这里漏了）。三处各回主线程取——L303-2 快照口径；deleteAppFiles 内部自管线程，见 3.8.900（L566-5），不再整段包 MainActor.run。
        let displayName = await MainActor.run { appInfo.displayName() ?? configuration.model.displayName }
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
        // 3.8.558（L307-1）：上面 await presentConfirmation 之后恢复在后台执行器上（非隔离 Task 的执行器是全局并发池、不是主线程），containers 读 _info 仍离主线程；单独再取一次快照。
        let containers = await MainActor.run { appInfo.containers }
        if !containers.isEmpty {
            shouldRemoveAppFolders = await presentConfirmation(
                title: "lc.appBanner.deleteDataTitle".loc,
                message: "lc.appBanner.deleteDataMsg %@".localizeWithFormat(displayName),
                confirmTitle: "lc.common.delete".loc,
                cancelTitle: "lc.common.no".loc
            ) == true
        }

        do {
            // 3.8.900（L566-5）：deleteAppFiles 自管线程——快照与列表移除在主线程、删文件在后台；这里不再整段包 MainActor.run（L307-1 原来包着是怕离主线程读 _info，现在函数内部已按该口径分段）。闭包非逃逸、抓 weak self 合法。
            let (failedContainers, keptBackupName) = try await Self.deleteAppFiles(configuration.model, removeDataFolders: shouldRemoveAppFolders) { [weak self] model in
                self?.delegate.removeApp(app: model)
            }
            var messages: [String] = []
            if !failedContainers.isEmpty {
                messages.append("以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
            }
            if let kept = keptBackupName {
                messages.append("备份「\(kept)」已锁定，已保留")
            }
            if !messages.isEmpty {
                showError(messages.joined(separator: "\n"))
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
        // L60-1：值里带 &（如 H&M.app）时 urlQueryAllowed 会放行它、
        // 接收侧从 & 处切断，改走 czfQueryValueAllowed（排除 &）。
        let encodedBundlePath = relativeBundlePath.addingPercentEncoding(withAllowedCharacters: .czfQueryValueAllowed) ?? relativeBundlePath
        if let folderName = configuration.model.uiSelectedContainer?.folderName {
            let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: .czfQueryValueAllowed) ?? folderName
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
            // 3.8.564（L303-2）：generateWebClipConfig 内部读 displayName ×4 + bundleIdentifier ×1，
            // 全是 _info 读；本函数从横幅卡裸 Task 调来、不在主线程（L33 同款），
            // L33 只包了 installMdm 的 MainActor.run。整段调回主线程再做（guard 条件里
            // await MainActor.run 不能跟尾随闭包，写 body: 标签，610 同款）。
            guard let profile = await MainActor.run(body: {
                configuration.model.appInfo.generateWebClipConfig(
                    withContainerId: configuration.model.uiSelectedContainer?.folderName,
                    iconStyle: style
                )
            }) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            // 3.8.511（L33）：裸 Task 不在主 actor 上，installMdm 写
            // @State（safariViewURL/safariViewOpened，fullScreenCover
            // 的开关），必须回主线程，否则 App Clip 配置页可能打不开
            //（L32 toggleHidden 同款；网格那路是 SwiftUI 主 actor，不动）。
            await MainActor.run {
                self.delegate.installMdm(data: data)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }
        // 3.8.564（L303-2）：displayName() 读 _info，本函数从横幅卡裸 Task 调来、不在主线程（L33 同款）；
        // L33 只把 UIKit 判窗/present 包进 MainActor.run，漏了这次 _info 读。入口先回主线程取一次名，后面只用局部量。
        let rawDisplayName = await MainActor.run { configuration.model.appInfo.displayName() ?? configuration.model.displayName }

        do {
            guard let image = configuration.model.appInfo.generateLiveContainerWrappedIcon(with: style),
                  let imageData = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }

            cleanupExportTemporaryDirectory()
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
            let fileURL = temporaryDirectory.appendingPathComponent("\(displayName) Icon.png")
            try imageData.write(to: fileURL, options: .atomic)
            exportTemporaryDirectory = temporaryDirectory

            // 3.8.511（L33）：saveIcon 从横幅卡裸 Task 调来、不在主
            // actor 上，viewIfLoaded 的判窗与 present 都是 UIKit 活，
            // 必须回主线程再判、再弹，否则选择器静默弹不出来、临时
            // 目录还漏了（delegate 回调永不触发）。单跳 MainActor.run
            // 里判完即弹，中间无挂起；弹不出返回 false 再清临时目录。
            let czfPresented = await MainActor.run { () -> Bool in
                guard viewIfLoaded?.window != nil, presentedViewController == nil else {
                    return false
                }
                let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
                documentPicker.delegate = self
                documentPicker.presentationController?.delegate = self
                present(documentPicker, animated: true)
                return true
            }
            guard czfPresented else {
                cleanupExportTemporaryDirectory()
                return
            }
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

    // 3.8.647（F3）：列表模式导出 IPA——网格菜单 czfExportIPA() 同款：
    // 后台线程拷包 + 打包（大包压缩别卡主线程），完事回主线程用 UIKit
    // UIActivityViewController 直接 present（横幅卡是 UIKit VC，不走
    // SwiftUI 的 ActivityViewController）；completionWithItemsHandler
    // 里删 tmp 目录（网格同款清理语义：onComplete 才删，取消也删）；
    // czfExporting 防重入；失败走现有 showError。bundlePath 与导出中
    // 标志都在主线程上取/置（菜单回调在主线程上）；Task.detached 里
    // 只用已取出的本地字符串，不碰 VC 状态。
    private func czfExportIPA() {
        guard !czfExporting else { return }
        guard let bundlePath = configuration.model.appInfo.bundlePath() else {
            showError("找不到 App 包路径")
            return
        }
        czfExporting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try LCUtils.czfExportIPA(forBundlePath: bundlePath)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.czfExporting = false
                    guard self.viewIfLoaded?.window != nil, self.presentedViewController == nil else {
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                        return
                    }
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    activity.completionWithItemsHandler = { _, _, _, _ in
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                    if let popover = activity.popoverPresentationController {
                        popover.sourceView = self.view
                        popover.sourceRect = self.view.bounds
                    }
                    self.present(activity, animated: true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.czfExporting = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }
}
