import Foundation

protocol LCAppModelDelegate {
    func closeNavigationView()
    func changeAppVisibility(app : LCAppModel)
    func jitLaunch(appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt, selectedBundlePath: String?, selectedContainerFolder: String?, launchURL: String?) async -> Bool
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async
    func showRunWhenMultitaskAlert() async -> Bool?
}

class LCAppModel: ObservableObject, Hashable {
    
    @Published var appInfo : LCAppInfo
    
    @Published var isAppRunning = false
    // 同步启动互斥（3.8.459 审计）：isAppRunning 的置位在
    // runApp 内多个 await 之后，连点两次会双双越过首行守卫、
    // 双签双起（同容器还会在启动门里挂两个同 uuid 等待者）。
    // 这把锁在首行同步抢占、中间无 await 间隙；全程持有，
    // 退出即放。isAppRunning 仍是 UI 侧的运行指示，不动它。
    private let czfLaunchLock = NSLock()
    private var czfLaunchInFlight = false
    private func czfClaimLaunch() -> Bool {
        czfLaunchLock.lock()
        defer { czfLaunchLock.unlock() }
        guard !czfLaunchInFlight else { return false }
        czfLaunchInFlight = true
        return true
    }
    private func czfReleaseLaunch() {
        czfLaunchLock.lock()
        czfLaunchInFlight = false
        czfLaunchLock.unlock()
    }

    // S-1/F-1/F-2：共享锁守卫（全仓唯一一份新入口共用；banner、
    // 列表、launchAppWithBundleId 的现有守卫不动，不改它们的认证
    // 流程与报错出口）。锁了且没解锁过就先弹人脸，通过返回 true；
    // 取消或抛错返回 false，调用方直接 return。
    // LCUtils.authenticateUser 成功后置 isHiddenAppUnlocked，后面
    // 同款检查直接短路，不弹第二次人脸。静态版供只有 LCAppInfo
    // 的入口（坞图标/运行条/右缘轮切）用；实例版供有 LCAppModel
    // 的入口用，谓词只写在静态版这一处。
    static func czfAuthenticateIfLocked(appInfo: LCAppInfo) async -> Bool {
        // 3.8.544（L74）：守卫在坞/运行条/源页/恢复页的裸 Task 里调（MultitaskDockView:1992/5223 等）；isLocked 读 _info、isHiddenAppUnlocked 是 @Published（Shared.swift:123），离主线程读是 L69/L70 同款；一点取齐再判。
        let (locked, unlocked) = await MainActor.run { (appInfo.isLocked, DataManager.shared.model.isHiddenAppUnlocked) }
        guard locked && !unlocked else { return true }
        do {
            return try await LCUtils.authenticateUser()
        } catch {
            return false
        }
    }

    func czfAuthenticateIfLocked() async -> Bool {
        await Self.czfAuthenticateIfLocked(appInfo: appInfo)
    }

    // MARK: - F-4/F-10：带回 / 拉满 / 最小化 / 小窗口共用助手
    // banner / 网格 / 面板三处原来各写一遍“dock 里找条目 → 带回并
    // 拉满/还原小窗/最小化”与“起完等窗进 dock 再拉满”，行为已分叉
    // （面板只用 dataUUID 查 dock、拉满重试只等 2 秒；banner/网格
    // 用选中容器优先、等 6 秒）。抽到这里，三处共用同一份。
    // 调用约定：主线程调（调用方原来就是按钮动作 / MainActor.run，
    // 与被替换的代码一致）；认证不在这里做，调用方带回/启动前
    // 先过守卫（面板 F-1、banner O-3）。
    // runApp 内的 bringExistingMultitaskWindowIfNeeded 不走这里：
    // 它只带回不改尺寸、还管 launchAppUrlScheme，语义不同。

    /// 实例 UUID：选中容器的 folderName 优先，dataUUID 回落。
    /// banner 的 bannerInstanceUUID 与面板的 dataUUID 原来各取各的，
    /// 选中容器与 dataUUID 不一致时行为分叉；统一到这一处。
    var czfInstanceUUID: String? {
        uiSelectedContainer?.folderName ?? appInfo.dataUUID
    }

    /// dock 里找归属对得上的条目：没有条目、条目归属对不上、
    /// 或归属验不出（appInfo 缺失/路径为空）都返回 nil，调用方
    /// 走新起；宁可多起一个窗口，不顶错别人的。
    @available(iOS 16.0, *)
    private static func czfOwnedDockEntry(app: LCAppModel, uuid: String) -> DockAppModel? {
        guard let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == app.appInfo.relativeBundlePath else { return nil }
        return entry
    }

    /// F-10 回落：当前选中容器下没找到在跑窗口时，找本条目别的容器里
    /// 唯一在跑的窗口——App 在跑时用户切了容器，当前 uuid 已不是在跑
    /// 窗口的号；最小化/小窗口再按当前 uuid 查就查不到，会新起一个窗口
    /// 再最小化/缩小它，旧窗口还留在台面上。只认唯一：在跑窗口的容器
    /// 须在本条目的 uiContainers 里、归属须按路径对得上，且同包名别的
    /// 条目都没登记过这个容器（共享容器归属说不清，宁可不回落）；零个
    /// 或多个都返回 nil，调用方走老路新起。主线程调（读 dockManager.apps
    /// 与 DataManager.shared.model，与 czfOwnedDockEntry 同约定）。
    /// 3.8.550（L207）
    @available(iOS 16.0, *)
    private static func czfRunningEntryUnderOtherContainer(app: LCAppModel) -> DockAppModel? {
        let myFolders = Set(app.uiContainers.map { $0.folderName })
        guard let myPath = app.appInfo.relativeBundlePath, !myPath.isEmpty else { return nil }
        let currentUUID = app.czfInstanceUUID
        var found: DockAppModel?
        for entry in MultitaskDockManager.shared.apps {
            guard entry.appUUID != currentUUID,
                  myFolders.contains(entry.appUUID),
                  let runningPath = entry.appInfo?.relativeBundlePath, !runningPath.isEmpty,
                  runningPath == myPath else { continue }
            // 同包名别的条目也登记过这个容器时归属说不清，不回落。
            let sharedWithOther = (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).contains {
                $0 !== app && $0.bundleIdentifier == app.bundleIdentifier
                    && $0.uiContainers.contains { $0.folderName == entry.appUUID }
            }
            guard !sharedWithOther else { continue }
            guard found == nil else { return nil }
            found = entry
        }
        return found
    }

    /// F-4：带回共用——banner / 网格 / 面板三处原来各写一遍。
    /// dock 里归属对得上的条目 → 带回；maximize=true 时顺手拉满，
    /// false 时顺手还原成小窗（maximizeWindow 是切换式）。
    /// 返回 true = 已处理（调用方直接 return，不再新起）；
    /// false = 没带回（调用方走新起）。
    /// 死窗兜底：bring 没抬动、条目还在、不是本次 C4 清掉的死窗时，
    /// 窗已在前台——拉满路按旧行为返回 brought（拿不到 VC 时走新起），
    /// 小窗路返回 true（旧行为：只还原不重起）。
    /// 没有 dock 条目时：拉满路保留旧行为，只带回不拉满（没 decorated
    /// VC 可拉）；小窗路不试带回（旧行为：直接走未运行分支起新窗）。
    static func czfBringRunningAppToFront(_ app: LCAppModel, maximize: Bool) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        guard let uuid = app.czfInstanceUUID else { return false }
        let dockManager = MultitaskDockManager.shared
        if let runningApp = czfOwnedDockEntry(app: app, uuid: uuid) {
            var brought = false
            if #available(iOS 16.1, *) {
                brought = MultitaskWindowManager.openExistingAppWindow(dataUUID: uuid)
            }
            if !brought {
                brought = dockManager.bringMultitaskViewToFront(uuid: uuid)
            }
            // 带回成功拉满；带回失败但条目还在且不是本次 C4 清掉的
            // 死窗（窗已在前台、只是 bring 没抬动）同样拉满，别再
            // 静默空转回小窗。
            let cleanedByC4 = dockManager.czfLastBringCleanedDeadWindowUUID == uuid
            let entryGone = !dockManager.apps.contains(where: { $0.appUUID == uuid })
            if brought || (!cleanedByC4 && !entryGone) {
                // maximizeWindow 是切换式：拉满先判 !isMaximized，
                // 否则已是最大窗会被反切回小窗；还原先判 isMaximized。
                // 死窗兜底：bring 没抬动、条目还在、但拿不到 VC 时
                // 不是“窗已在前台”，是死窗——拉满路返回 brought
                // （false 即走新起），小窗路返回 true（只还原不重起）。
                if let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController {
                    if maximize {
                        if !vc.isMaximized {
                            vc.maximizeWindow()
                        }
                    } else if vc.isMaximized {
                        vc.maximizeWindow()
                    }
                    return true
                }
                return maximize ? brought : true
            }
        } else if dockManager.apps.contains(where: { $0.appUUID == uuid }) {
            // 条目在但归属对不上，不碰，返回 false 走新起。
            return false
        } else {
            // 没有 dock 条目（原生窗口模式等）：拉满路保留旧行为，
            // 只带回不拉满，带回失败再落到新起；小窗路不试带回。
            guard maximize else { return false }
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
        return false
    }

    /// F-10：还原小窗共用——banner 静态版与面板实例版原来各写一遍，
    /// 一字相同。窗口已最大化时点一下（maximizeWindow 是切换式）
    /// 还原成小窗。
    @available(iOS 16.0, *)
    static func czfUnmaximizeWindow(uuid: String) {
        guard let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let vc = runningApp.view?._viewDelegate() as? DecoratedAppSceneViewController,
              vc.isMaximized else { return }
        vc.maximizeWindow()
    }

    /// 小窗口回落路专用（3.8.239）：czfOnWindowAppeared 是“同 uuid
    /// 条目已存在就立即回调”、不验归属——同容器被别的条目占着时，
    /// 回调会把别人的窗口还原成小窗。动作前再按路径复验一次，
    /// 对不上/验不出就什么都不做，别动别人的窗口。
    @available(iOS 16.0, *)
    static func czfUnmaximizeWindowIfOwned(uuid: String, expectedPath: String?) {
        guard let expectedPath,
              let runningApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }),
              let runningPath = runningApp.appInfo?.relativeBundlePath, !runningPath.isEmpty,
              runningPath == expectedPath else { return }
        czfUnmaximizeWindow(uuid: uuid)
    }

    /// F-10 小窗口回落：本条目别的容器里唯一在跑的窗口，直接还原成
    /// 小窗（已是小窗或拿不到 VC 时 czfUnmaximizeWindow 本来就是空操作，
    /// 仍返回 true、不新起——与带回路“小窗路只还原不重起”同款）。
    /// 3.8.550（L207）
    @available(iOS 16.0, *)
    private static func czfSmallWindowFallback(app: LCAppModel) -> Bool {
        guard let entry = czfRunningEntryUnderOtherContainer(app: app) else { return false }
        czfUnmaximizeWindow(uuid: entry.appUUID)
        return true
    }

    /// F-10：最小化已在运行分支共用——banner 与面板原来各写一遍：
    /// dock 里归属对得上的条目 → 直接最小化。返回 true = 已处理。
    /// 最小化不露内容，不要认证；未运行分支的启动才要认证（调用方做）。
    static func czfMinimizeRunningWindow(_ app: LCAppModel) -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        if let uuid = app.czfInstanceUUID,
           czfOwnedDockEntry(app: app, uuid: uuid) != nil {
            MultitaskDockManager.shared.minimizeWindow(uuid: uuid)
            return true
        }
        // 3.8.550（L207）：App 在跑时切了容器，当前 uuid 下没窗口；
        // 别走未运行分支新起一个窗口再最小化它——旧窗口还留在台面上。
        // 本条目别的容器里唯一在跑的窗口就直接最小化它；没有或多个
        // 时走老路（多个时不猜，宁可新起）。
        guard let entry = czfRunningEntryUnderOtherContainer(app: app) else { return false }
        MultitaskDockManager.shared.minimizeWindow(uuid: entry.appUUID)
        return true
    }

    /// F-4：起完拉满共用——banner / 网格 / 面板三处原来各写一遍
    /// “等窗进 dock → 按路径验归属 → 拉满”，重试上限统一 6 秒
    /// （面板原来 2 秒，签名慢的包拉不满）。uuid 每轮重取：容器
    /// 中途换了就跟新值（面板同款语义，F-3 同款保护）。
    @available(iOS 16.0, *)
    static func czfPollAndMaximizeFreshWindow(app: LCAppModel) {
        let expectedPath = app.appInfo.relativeBundlePath
        let deadline = Date().addingTimeInterval(6)
        czfWaitUUIDThenMaximizeFreshWindow(app: app, expectedPath: expectedPath, deadline: deadline)
    }

    /// 容器还没建出来（uuid 为空）时等容器出现再注册窗口回调，
    /// 上限 6 秒（原轮询同款预算）；等不到就停，不报错。
    @available(iOS 16.0, *)
    private static func czfWaitUUIDThenMaximizeFreshWindow(app: LCAppModel, expectedPath: String?, deadline: Date) {
        if let uuid = app.czfInstanceUUID {
            MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: max(0, deadline.timeIntervalSinceNow)) {
                czfRetryMaximizeFreshWindow(app: app, deadline: deadline)
            }
            return
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            czfWaitUUIDThenMaximizeFreshWindow(app: app, expectedPath: expectedPath, deadline: deadline)
        }
    }

    /// 返回 true = 已处理完（已拉满，或归属不对停表不再碰）。
    /// uuid 每轮重取：容器中途换了就跟新值。
    @available(iOS 16.0, *)
    private static func czfTryMaximizeFreshWindow(app: LCAppModel) -> Bool {
        let expectedPath = app.appInfo.relativeBundlePath
        guard let uuid = app.czfInstanceUUID,
              let entry = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == uuid }) else { return false }
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
    private static func czfRetryMaximizeFreshWindow(app: LCAppModel, deadline: Date) {
        guard !czfTryMaximizeFreshWindow(app: app) else { return }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            czfRetryMaximizeFreshWindow(app: app, deadline: deadline)
        }
    }

    /// F-10：最小化共用助手——banner 与面板共用（带回 + 归属校验 +
    /// 未运行启动 + 超时反馈四段里的后三段由骨架做，运行中分支
    /// 在这里）。调用方负责认证（banner 在按钮里先过守卫，面板
    /// 在外层先认证）与关面板/记偏好。onError 是失败反馈出口
    /// （banner 传 showError，面板传 reportLaunchError）；
    /// onProceed 在 uuid 验过后立刻调一次（面板用它关面板，
    /// banner 不用，默认空）——运行中分支与未运行分支都只关这一次，
    /// 助手返回后调用方不用再关。
    static func czfMinimizeApp(
        _ app: LCAppModel,
        onError: @escaping (String) -> Void,
        onProceed: @escaping () -> Void = {}
    ) async {
        guard #available(iOS 16.0, *) else { return }
        // 3.8.544（L74）：本函数从横幅卡/面板的裸 Task 调来；czfInstanceUUID 读 @Published uiSelectedContainer + _info dataUUID，超时文案的 displayName 读 _info，离主线程读是 L69/L70 同款；入口一次取齐。
        let (instanceUUID, displayName) = await MainActor.run { (app.czfInstanceUUID, app.appInfo.displayName() ?? "App") }
        guard instanceUUID != nil else { return }
        // 3.8.535（L62-1）：本函数从横幅卡/面板的裸 Task 调来、不在主
        // actor 上，onProceed 是面板的 closePanel（dismissPanelOverlay
        // 直接动 UIView/dismiss），必须回主线程再调；横幅卡传默认
        // 空闭包，无行为变化。L38 只包了小窗口路的带回，没包这里。
        await MainActor.run { onProceed() }
        // 3.8.539（L69）：同款漏网——czfMinimizeRunningWindow 里
        // czfOwnedDockEntry 读 @Published dockManager.apps（L67
        // 修的是 pruneStaleDockEntries 改它的写侧，这是读侧），
        // 本函数从横幅卡/面板的裸 Task 调来，读时主线程正增删
        // 同一数组（add/prune/remove），Swift 数组读-写并发
        // 是数据竞态、可能崩；minimizeWindow 自身已 dispatch
        // 到主线程，读也回主线程再做（L64-3 同款 body: 标签形）。
        if await MainActor.run(body: { czfMinimizeRunningWindow(app) }) { return }
        let expectedPath = app.appInfo.relativeBundlePath
        let dockManager = MultitaskDockManager.shared
        await czfLaunchThenActOnWindow(
            app: app,
            multitask: nil,
            timeout: 6,
            timeoutMessage: "最小化超时：6 秒内没等到「\(displayName)」的窗口，请确认 App 已打开后重试",
            action: { waitUUID in
                if let entry = dockManager.apps.first(where: { $0.appUUID == waitUUID }) {
                    let owned = entry.appInfo?.relativeBundlePath.map { !$0.isEmpty && $0 == expectedPath } ?? false
                    if owned {
                        dockManager.minimizeWindow(uuid: waitUUID)
                    }
                }
            },
            onError: onError
        )
    }

    /// F-10：小窗口共用助手——banner 与面板共用。未运行分支：
    /// 窗出来 0.35 秒后还原为小窗；30 秒未出现放弃等，到期报一次
    /// 超时（F-3：原来静默放弃）。其余约定与 czfMinimizeApp 同款。
    static func czfSmallWindowApp(
        _ app: LCAppModel,
        onError: @escaping (String) -> Void,
        onProceed: @escaping () -> Void = {}
    ) async {
        guard #available(iOS 16.0, *) else { return }
        // 3.8.544（L74）：同 czfMinimizeApp——裸 Task 执行器上读 @Published + _info；入口一次取齐。
        let (instanceUUID, displayName) = await MainActor.run { (app.czfInstanceUUID, app.appInfo.displayName() ?? "App") }
        guard instanceUUID != nil else { return }
        // 3.8.535（L62-1）：同 czfMinimizeApp——onProceed 是面板的
        // closePanel（dismissPanelOverlay 直接动 UIView/dismiss），
        // 裸 Task 执行器上调会离主线程动 UI；回主线程再调。
        await MainActor.run { onProceed() }
        // 3.8.514（L38）：本函数从横幅卡裸 Task 调来、不在主 actor
        // 上，czfBringRunningAppToFront 是纯 UIKit 活（带回/拉满），
        // 必须回主线程再调（横幅卡 :202 与面板 :1510 两处调用方
        // 已是 await MainActor.run 包着的同款写法，这里是漏掉
        // 的第三处）。
        if await MainActor.run(body: { czfBringRunningAppToFront(app, maximize: false) }) { return }
        // 3.8.550（L207）：同最小化——App 在跑时切了容器，带回按当前
        // uuid 查不到，直接走未运行分支会新起一个窗口再缩小、旧窗口
        // 还留在台面上；本条目别的容器里唯一在跑的窗口就直接还原它。
        if await MainActor.run(body: { czfSmallWindowFallback(app: app) }) { return }
        let expectedPath = app.appInfo.relativeBundlePath
        await czfLaunchThenActOnWindow(
            app: app,
            multitask: true,
            timeout: 30,
            timeoutMessage: "小窗口超时：30 秒内没等到「\(displayName)」的窗口，请确认 App 已打开后重试",
            action: { waitUUID in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    czfUnmaximizeWindowIfOwned(uuid: waitUUID, expectedPath: expectedPath)
                }
            },
            onError: onError
        )
    }

    /// F-10：未运行分支的共用骨架——最小化/小窗口共用：
    /// ① 调 launch 启动（启动失败经 onError 报启动错、不再报超时，
    /// 此时还没注册过观察者，跳过项 25 的 stale 观察者不存在）；
    /// ② 启动完重读 uuid（拆容器换号走新号）再注册“窗出现即动作”
    /// 回调，窗已出现时当场调 handler；等窗预算从启动完成才起算
    /// （L155：原来先注册再启动，启动耗时吃掉预算、冷启动超 6 秒
    /// 时最小化必报超时）；③ 到期动作没跑就经 onError 报一次超时。
    /// action 在窗口出现时调；timeout 是启动完成后的等窗预算（秒）。
    @available(iOS 16.0, *)
    private static func czfLaunchThenActOnWindow(
        app: LCAppModel,
        multitask: Bool?,
        timeout: TimeInterval,
        timeoutMessage: String,
        action: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) async {
        // 3.8.544（L74）：同上，裸 Task 执行器上读 @Published + _info；现取。
        guard let uuid = await MainActor.run(body: { app.czfInstanceUUID }) else { return }
        do {
            try await app.runApp(multitask: multitask, containerFolderName: uuid)
        } catch {
            // 3.8.535（L62-1）：catch 跑在调用方裸 Task 的执行器上
            // （非隔离 async），onError 是面板的 reportLaunchError
            // （写 @State launchError）/横幅卡的 showError——前者
            // 离主线程写 @State 会丢更新、启动失败提示弹不出来
            // （“点了没反应”同款；超时那路已是 Task @MainActor）。
            // 回主线程再报。showError 自身已包主线程 dispatch，
            // 再包一层无害。
            await MainActor.run { onError(error.localizedDescription) }
            return
        }
        // 3.8.542（L155）：等窗预算从启动完成才起算——原来先注册
        // 再启动，czfOnWindowAppeared 的超时钟从注册那一刻就走，
        // 启动（签名/挂 JIT/客初始化）吃掉预算：冷启动超 6 秒时
        // 最小化必报“最小化超时”，明明 App 已打开、再点一次才好。
        // 改成启动完再注册：窗已出现时 czfOnWindowAppeared 见 apps
        // 里已有该 uuid、当场调 handler，不丢快启动；启动完重读
        // uuid（拆容器换号走新号，旧的双注册不要了）。附带：启动
        // 失败 early return 时还没注册过，跳过项 25 的 stale 观察
        // 者（失败后 30 秒内手动重开、大窗被缩成小窗）也不存在了。
        var done = false
        let act: (String) -> Void = { waitUUID in
            action(waitUUID)
            done = true
        }
        // 3.8.544（L74）：同上，启动完重读 uuid 也是离主线程读；现取。
        guard let waitUUID = await MainActor.run(body: { app.czfInstanceUUID }) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        MultitaskDockManager.shared.czfOnWindowAppeared(uuid: waitUUID, timeout: timeout) {
            act(waitUUID)
        }
        Task { @MainActor in
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            if !done {
                onError(timeoutMessage)
            }
        }
    }

    @Published var isSigningInProgress = false
    @Published var signProgress = 0.0
    private var observer : NSKeyValueObservation?
    
    @Published var uiIsJITNeeded : Bool {
        didSet {
            appInfo.isJITNeeded = uiIsJITNeeded
        }
    }
    @Published var uiHelperProcessesSupport: Bool {
        didSet {
            appInfo.helperProcessesSupport = uiHelperProcessesSupport
        }
    }
    @Published var uiClassicMode : Bool {
        didSet {
            appInfo.classicMode = uiClassicMode
        }
    }
    @Published var uiIsHidden : Bool
    @Published var uiIsLocked : Bool
    @Published var uiIsShared : Bool
    @Published var uiDefaultDataFolder : String?
    @Published var uiContainers : [LCContainer]
    @Published var uiSelectedContainer : LCContainer?
    @Published var uiIs32bit : Bool
    @Published var uiIs32bitEmulator : Bool
    @Published var uiTweakFolder : String? {
        didSet {
            appInfo.tweakFolder = uiTweakFolder
        }
    }
    /// 模块文件夹多选：存储仍是一个字符串（LCTweakFolder），
    /// 多个文件夹名用 | 拼接——旧的单值天然就是单元素，向后
    /// 兼容不用迁移。TweakLoader 侧按同一规则拆开逐个加载
    static func czfSplitTweakFolders(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "|").map { String($0) }.filter { !$0.isEmpty }
    }
    static func czfJoinTweakFolders(_ folders: [String]) -> String? {
        folders.isEmpty ? nil : folders.joined(separator: "|")
    }
    var uiTweakFolders: [String] {
        Self.czfSplitTweakFolders(uiTweakFolder)
    }
    func toggleTweakFolder(_ name: String) {
        var folders = uiTweakFolders
        if let idx = folders.firstIndex(of: name) {
            folders.remove(at: idx)
        } else {
            folders.append(name)
        }
        uiTweakFolder = Self.czfJoinTweakFolders(folders)
    }
    @Published var uiDoSymlinkInbox : Bool {
        didSet {
            appInfo.doSymlinkInbox = uiDoSymlinkInbox
        }
    }
    @Published var uiUseLCBundleId : Bool {
        didSet {
            appInfo.doUseLCBundleId = uiUseLCBundleId
        }
    }
    
    @Published var uiFixFilePickerNew : Bool {
        didSet {
            appInfo.fixFilePickerNew = uiFixFilePickerNew
        }
    }
    @Published var uiFixLocalNotification : Bool {
        didSet {
            appInfo.fixLocalNotification = uiFixLocalNotification
        }
    }
    @Published var uiFixBackgroundTaskIdentifiers : Bool {
        didSet {
            appInfo.fixBackgroundTaskIdentifiers = uiFixBackgroundTaskIdentifiers
        }
    }
    
    @Published var uiHideLiveContainer : Bool {
        didSet {
            appInfo.hideLiveContainer = uiHideLiveContainer
        }
    }
    @Published var uiTweakLoaderInjectFailed : Bool
    @Published var uiDontInjectTweakLoader : Bool {
        didSet {
            appInfo.dontInjectTweakLoader = uiDontInjectTweakLoader
        }
    }
    @Published var uiDontLoadTweakLoader : Bool {
        didSet {
            appInfo.dontLoadTweakLoader = uiDontLoadTweakLoader
        }
    }
    @Published var uiOrientationLock : LCOrientationLock {
        didSet {
            appInfo.orientationLock = uiOrientationLock
        }
    }
    @Published var uiSelectedLanguage : String {
        didSet {
            appInfo.selectedLanguage = uiSelectedLanguage
        }
    }
    
    @Published var uiDontSign : Bool {
        didSet {
            appInfo.dontSign = uiDontSign
        }
    }
    
    @Published var jitLaunchScriptJs: String? {
        didSet {
            appInfo.jitLaunchScriptJs = jitLaunchScriptJs
        }
    }
    
    @Published var uiSelected32BitEmulator : String {
        didSet {
            appInfo.selected32BitEmulator = uiSelected32BitEmulator
        }
    }
    
    @Published var uiSpoofSDKVersion : Bool {
        didSet {
            appInfo.spoofSDKVersion = uiSpoofSDKVersion
        }
    }
    
    @Published var uiRemark : String {
        didSet {
            appInfo.remark = uiRemark
        }
    }

    // 多开自定义名：改这里就改列表名和之后备份的文件夹名，
    // 清空 = 回到包内原名。
    @Published var uiCustomDisplayName : String {
        didSet {
            appInfo.customDisplayName = uiCustomDisplayName
        }
    }
    
    @Published var uiIsMultitaskModeSpecificed : MultitaskSpecified {
        didSet {
            appInfo.multitaskSpecified = uiIsMultitaskModeSpecificed;
        }
    }
    
    public var bundleIdentifier: String {
        get {
            return appInfo.bundleIdentifier() ?? "?"
        }
    }
    
    public var version: String {
        get {
            return appInfo.version() ?? "?"
        }
    }
    
    public var displayName: String {
        get {
            return appInfo.displayName() ?? "?"
        }
    }
    
    public var shouldLaunchInMultitaskMode : Bool {
        get {
            if #available(iOS 16.0, *) {
                return uiIsMultitaskModeSpecificed == .yes ||
                (uiIsMultitaskModeSpecificed == .default && UserDefaults.standard.bool(forKey: "LCLaunchInMultitaskMode"))
            } else {
                return false
            }
        }
    }
    
    @Published var supportedLanguages : [String]?
    
    var delegate : LCAppModelDelegate?
    
    init(appInfo : LCAppInfo, delegate: LCAppModelDelegate? = nil) {
        self.appInfo = appInfo
        self.delegate = delegate

        if !appInfo.isLocked && appInfo.isHidden {
            appInfo.isLocked = true
        }
        
        self.uiIsJITNeeded = appInfo.isJITNeeded
        self.uiHelperProcessesSupport = appInfo.helperProcessesSupport
        self.uiClassicMode = appInfo.classicMode
        self.uiIsHidden = appInfo.isHidden
        self.uiIsLocked = appInfo.isLocked
        self.uiIsShared = appInfo.isShared
        self.uiSelectedLanguage = appInfo.selectedLanguage ?? ""
        self.uiDefaultDataFolder = appInfo.dataUUID
        self.uiContainers = appInfo.containers
        self.uiTweakFolder = appInfo.tweakFolder
        self.uiDoSymlinkInbox = appInfo.doSymlinkInbox
        self.uiOrientationLock = appInfo.orientationLock
        self.uiIsMultitaskModeSpecificed = appInfo.multitaskSpecified
        self.uiUseLCBundleId = appInfo.doUseLCBundleId
        self.uiFixFilePickerNew = appInfo.fixFilePickerNew
        self.uiFixLocalNotification = appInfo.fixLocalNotification
        self.uiFixBackgroundTaskIdentifiers = appInfo.fixBackgroundTaskIdentifiers
        self.uiHideLiveContainer = appInfo.hideLiveContainer
        self.uiDontInjectTweakLoader = appInfo.dontInjectTweakLoader
        self.uiTweakLoaderInjectFailed = appInfo.info()["LCTweakLoaderCantInject"] as? Bool ?? false
        self.uiDontLoadTweakLoader = appInfo.dontLoadTweakLoader
        self.uiDontSign = appInfo.dontSign
        self.jitLaunchScriptJs = appInfo.jitLaunchScriptJs
        self.uiSelected32BitEmulator = appInfo.selected32BitEmulator ?? ""
        self.uiSpoofSDKVersion = appInfo.spoofSDKVersion
        self.uiRemark = appInfo.remark ?? ""
        self.uiCustomDisplayName = appInfo.customDisplayName ?? ""
        self.uiIs32bit = appInfo.is32bit
        self.uiIs32bitEmulator = appInfo.is32bitEmulator
        for container in uiContainers {
            if container.folderName == uiDefaultDataFolder {
                self.uiSelectedContainer = container;
                break
            }
        }
    }
    
    static func == (lhs: LCAppModel, rhs: LCAppModel) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
    
    // 多开数据隔离：同包名有多个 App 条目（不同名字、不同包
    // 文件夹）时，各实例必须各用各的数据。LiveContainer 默认
    // 有两条共享通道：App Group 默认不隔离（所有容器走同一
    // 个 AppGroup 文件夹）、钥匙串组是 0..<128 随机（多实例
    // 时会撞组，撞上就共用登录态）。新容器、已有容器都在启
    // 动时一次性隔离：App Group 隔离 + 厂商标识伪装 + 钥匙串
    // 组改成同包名下没人用的组。按容器打标记、只隔离一次，之
    // 后用户在容器设置里亲手改的开关不再被自动翻回去。
    private func czfOtherSameBundleApps() -> [LCAppModel] {
        let myPath = appInfo.relativeBundlePath
        return (DataManager.shared.model.apps + DataManager.shared.model.hiddenApps).filter {
            $0 !== self && $0.bundleIdentifier == bundleIdentifier && $0.appInfo.relativeBundlePath != myPath
        }
    }
    private func czfFreeKeychainGroup(excluding container: LCContainer) -> Int {
        var used = Set<Int>()
        for app in DataManager.shared.model.apps + DataManager.shared.model.hiddenApps {
            for c in app.uiContainers where c !== container {
                let g = c.keychainGroupId
                if g >= 0 { used.insert(g) }
            }
        }
        for c in uiContainers where c !== container {
            let g = c.keychainGroupId
            if g >= 0 { used.insert(g) }
        }
        let free = (0..<SharedModel.keychainAccessGroupCount).filter { !used.contains($0) }
        return free.randomElement() ?? Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
    }
    // 多开容器拆分（视频实证）：同包名两个 App 条目若指到
    // 同一个容器文件夹，启动时按容器找窗口、按容器查占用都会
    // 把第一个的窗口顶回来，第二个永远起不来，数据、登录态
    // 也天然同一份。v189 只改了钥匙串组/App Group/厂商标识，
    // 没动这条按容器找窗口的路由，盖不住它。启动前若选中
    // 的容器被同包名别的条目也在用，就给本条目新建一个空
    // 容器并切过去：旧容器留在列表里不删，旧数据归原来那
    // 个条目，新条目从空数据起，之后各用各的。只拆选中
    // 的那一个，不动别的容器。
    /// 3.8.520（L46）：克隆包文件夹名里的毫秒时间戳（`包名_<毫秒>.app`，
    /// 见 LCAppListView:2538）；不是克隆名（无 `_数字.app` 尾巴）返 nil。
    /// 毫秒时间戳约 7.8e11，Int（64 位）装得下。
    private static func czfCloneTimestamp(from path: String) -> Int? {
        guard let range = path.range(of: "_\\d+\\.app$", options: .regularExpression) else { return nil }
        let digits = path[range].dropFirst().dropLast(4) // 去掉 "_" 与 ".app"
        return Int(digits)
    }

    private func czfSplitSharedContainerIfNeeded() {
        guard !czfOtherSameBundleApps().isEmpty else { return }
        guard let selected = uiSelectedContainer else { return }
        let sharedFolder = selected.folderName
        let isSharedWithOther = czfOtherSameBundleApps().contains { other in
            other.uiContainers.contains { $0.folderName == sharedFolder }
        }
        guard isSharedWithOther else { return }
        // 拆分换容器时把待恢复的钥匙串排队文件一起带过去：
        // 恢复只把 CZFKeychainImport.plist 写进恢复时已有的容器，
        // 启动若切到别的容器（复用旧的或新建的），文件留在旧容器
        // 里、桥在新容器里看不到，imported=0/0、登录回不来——
        // 多开 App 时好时坏的根因之一。文件跟启动走；目标已有
        // 文件时不动（恢复时已写过一份），只补缺的。
        let carryPendingKeychainImport: (LCContainer) -> Void = { newContainer in
            let fm = FileManager.default
            let src = selected.containerURL.appendingPathComponent("CZFKeychainImport.plist")
            let dst = newContainer.containerURL.appendingPathComponent("CZFKeychainImport.plist")
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // 旧数据归先装的那一个：先装的条目不拆、继续用旧容器，
        // 后装的条目才拆到新容器，不然先启动的那个反而丢了
        // 旧数据、后启动的那个却捡了旧数据，完全反了。先按
        // installationDate 判，缺失时按包文件夹名判：克隆的
        // 文件夹是 包名_时间戳.app，原装的是 包名.app。
        // 3.8.524（L51）：三条目以上共用同一容器时，“先装的不拆”
        // 必须对全部共用者取与——原来循环里遇上第一个比自己新
        // 的就 return，中间那个（比一个旧、比一个新）永远拆不
        // 出去，一直跟最早的那个共用容器：按容器找窗口会把最
        // 早那个的窗口顶回来、中间这个永远起不来，登录态也
        // 天然同一份。改成先攒“比全部共用者都早”再决定。
        var czfSelfIsEarliest = true
        for other in czfOtherSameBundleApps() where other.uiContainers.contains(where: { $0.folderName == sharedFolder }) {
            if let myDate = appInfo.installationDate, let otherDate = other.appInfo.installationDate {
                if !(myDate < otherDate) { czfSelfIsEarliest = false }
            } else {
                let myPath = appInfo.relativeBundlePath ?? ""
                let otherPath = other.appInfo.relativeBundlePath ?? ""
                // 3.8.520（L46）：两个都是克隆时光凭“带不带时间戳”
                // 分不出先后——克隆名是 包名_毫秒时间戳.app
                // （LCAppListView:2538），先装的克隆时间戳小。
                // 只比有没有戳会让先装的克隆也拆走，旧数据反而归
                // 后装的那个，与上面“旧数据归先装的”正好反了。
                // 先比数字时间戳，都能解析出来时小的那个不拆；
                // 有一边解析不出来才回落到有戳/无戳判。
                if let myStamp = Self.czfCloneTimestamp(from: myPath),
                   let otherStamp = Self.czfCloneTimestamp(from: otherPath) {
                    if !(myStamp < otherStamp) { czfSelfIsEarliest = false }
                } else {
                    let myStamped = myPath.range(of: "_\\d+\\.app$", options: .regularExpression) != nil
                    let otherStamped = otherPath.range(of: "_\\d+\\.app$", options: .regularExpression) != nil
                    if !(!myStamped && otherStamped) { czfSelfIsEarliest = false }
                }
            }
        }
        if czfSelfIsEarliest { return }
        // 已有不共享的容器时直接切过去，不再新建（容器越生越多根因之二）：
        // 共享容器被重选（旧备份恢复把 dataUUID 指回旧容器、菜单点回旧容器）
        // 时，原来每次都要造一个新 UUID，列表只增不减；本条目自己的容器
        // （上次拆出来的、最新那个）数据就是本条目的，复用它隔离性不变，
        // 还保住了数据。取最后一个：多次拆分留下的孤儿在前面，最新在最后。
        // 本条目一个不共享的容器都没有时，才走下面新建。
        let others = czfOtherSameBundleApps()
        if let own = uiContainers.filter({ folder in
            !others.contains { other in
                other.uiContainers.contains { $0.folderName == folder.folderName }
            }
        }).last {
            uiSelectedContainer = own
            uiDefaultDataFolder = own.folderName
            appInfo.dataUUID = own.folderName
            carryPendingKeychainImport(own)
            return
        }
        let newName = NSUUID().uuidString
        let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
        newContainer.enableMultiOpenIsolation()
        let group = czfFreeKeychainGroup(excluding: newContainer)
        uiContainers.append(newContainer)
        uiSelectedContainer = newContainer
        appInfo.containers = uiContainers
        newContainer.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier, keychainGroupId: group)
        appInfo.dataUUID = newName
        uiDefaultDataFolder = newName
        carryPendingKeychainImport(newContainer)
    }
    // L89-2：按容器记“已隔离一次”的键（文件夹名是 UUID，全局唯一）。
    private static let czfMultiOpenIsolatedContainersKey = "CZFMultiOpenIsolatedContainers"

    private func czfIsolateMultiOpenContainersIfNeeded() {
        guard !czfOtherSameBundleApps().isEmpty else { return }
        // 3.8.558（L89）：V2 全局标记已删（L89-1）——原来立标记后永不
        // 再跑，但容器后来还能再加（设置页新建容器、恢复建容器、重新
        // 登记旧文件夹三路都不带隔离，LCContainer 三旗默认全
        // false），新容器永远得不到隔离、指纹/IDFV 与原身撞车。
        // 但光删标记不够（L89-2）：本循环见旗关着就全翻回开，每次
        // 启动都跑一遍，设置页里亲手关掉的隔离开关下次启动又被悄
        // 悄打开——与上面“亲手改的开关不再被自动翻回去”正好反了。
        // 改按容器记“已隔离一次”：UserDefaults 里记已处理过的容器
        // 文件夹名集，只对没记过的容器跑一次隔离，跑完就记下来，
        // 已处理过的哪怕用户后来关了旗也不再碰。共享容器不记
        // （它本来就不隔离；以后拆分出来的是新容器，会自己走
        // 一遍）。首轮种子：已隔离过的容器在 plist 里留有伪装值
        // （spoofedIdentifier / spoofedAdvertisingIdentifier /
        // spoofedMachine，didSet 开旗时生成、关旗不清除），从没隔
        // 离过的全是 nil——有任一伪装值或任一旗开着就算已处理过，
        // 只记不动；三旗全关且无伪装值的才是没隔离过的新容器。
        // 记录丢了也不怕：种子判据只看容器自身状态，丢了下次重
        // 跑一遍、已隔离过的照样只记不动。
        var isolatedFolders = Set(UserDefaults.standard.stringArray(forKey: Self.czfMultiOpenIsolatedContainersKey) ?? [])
        var isolatedChanged = false
        var otherGroups = Set<Int>()
        var otherFolders = Set<String>()
        for app in czfOtherSameBundleApps() {
            for c in app.uiContainers {
                otherFolders.insert(c.folderName)
                let g = c.keychainGroupId
                if g >= 0 { otherGroups.insert(g) }
            }
        }
        for container in uiContainers {
            // 共享容器不碰：它的 plist 是两个条目共用的文件，改它
            // 会把另一个条目的组也翻掉，来回 ping-pong；拆分后
            // 选中的已是新容器，旧共享容器只留给原来那个条目。
            if otherFolders.contains(container.folderName) { continue }
            if isolatedFolders.contains(container.folderName) {
                // 已处理过一次：组照常记进 otherGroups（后跑的容器
                // 挑空闲组时别撞上它），其余不动。
                if container.keychainGroupId >= 0 { otherGroups.insert(container.keychainGroupId) }
                continue
            }
            let czfAlreadyIsolated = container.isolateAppGroup || container.spoofIdentifierForVendor || container.spoofDeviceFingerprint || container.spoofedIdentifier != nil || container.spoofedAdvertisingIdentifier != nil || container.spoofedMachine != nil
            if !czfAlreadyIsolated {
                var newGroup = container.keychainGroupId
                if newGroup < 0 || otherGroups.contains(newGroup) {
                    newGroup = czfFreeKeychainGroup(excluding: container)
                }
                if !container.isolateAppGroup || !container.spoofIdentifierForVendor || !container.spoofDeviceFingerprint || container.keychainGroupId != newGroup {
                    container.enableMultiOpenIsolation()
                    container.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier, keychainGroupId: newGroup)
                }
                if newGroup >= 0 { otherGroups.insert(newGroup) }
            } else if container.keychainGroupId >= 0 {
                otherGroups.insert(container.keychainGroupId)
            }
            isolatedFolders.insert(container.folderName)
            isolatedChanged = true
        }
        if isolatedChanged {
            UserDefaults.standard.set(Array(isolatedFolders), forKey: Self.czfMultiOpenIsolatedContainersKey)
        }
    }

    // You should let LCAppModel.runApp to decide whether to run in multitask mode, but you may override the multitask parameter if necessary
    func runApp(multitask: Bool? = nil, containerFolderName : String? = nil, bundleIdOverride : String? = nil, urlStr : String? = nil, forceJIT: Bool? = nil) async throws{
        // 先抢同步锁再读 isAppRunning：forceResign 也抢同一把
        // 锁（3.8.526/L53），两重守卫各拦一侧。
        guard czfClaimLaunch() else {
            return
        }
        defer { czfReleaseLaunch() }
        // 3.8.547（L77）：isAppRunning 是 @Published，runApp 是非隔离 async、裸 Task 执行器上读是 L69/L70 同款；回主线程读（锁已抢到手，读与置位之间别的启动进不来）。
        if await MainActor.run(body: { isAppRunning }) {
            return
        }

        // 3.8.510（L32）：容器准备整段放主 actor 上——LCAppModel.runApp
        // 是非隔离 async，横幅卡（LCAppBannerViewController，普通
        // UIViewController 非 @MainActor）与 openSideStore 的裸 Task
        // 调它时整段都在全局执行器上，uiContainers/uiSelectedContainer/
        // uiDefaultDataFolder 与容器自身的 isolate/spoof 三旗全是
        // @Published，离主线程发更新、选中容器可能不刷新。段内无
        // await、只做快活（建容器、写 plist、拷 keychain 导入），
        // 主线程上跑无妨；其余调用方本来就在主 actor 上，包一层无害。
        await MainActor.run {
            if uiContainers.isEmpty {
                let newName = NSUUID().uuidString
                let newContainer = LCContainer(folderName: newName, name: newName, isShared: uiIsShared)
                let isMultiOpen = !czfOtherSameBundleApps().isEmpty
                let group: Int
                if isMultiOpen {
                    newContainer.enableMultiOpenIsolation()
                    group = czfFreeKeychainGroup(excluding: newContainer)
                } else {
                    group = Int.random(in: 0..<SharedModel.keychainAccessGroupCount)
                }
                uiContainers.append(newContainer)
                if uiSelectedContainer == nil {
                    uiSelectedContainer = newContainer;
                }
                appInfo.containers = uiContainers;
                newContainer.makeLCContainerInfoPlist(appIdentifier: appInfo.bundleIdentifier()!, keychainGroupId: group)
                // 3.8.377：卸载重装后首次启动新建容器时，把磁盘上已有容器里的
                // CZFKeychainImport.plist 带过来——恢复时排队文件只写进了旧容器
                // 37EDAD10（375 的恢复时循环是空操作：恢复时根本不存在第二个
                // 容器），新容器里没有，桥就读不到令牌。只补缺的，不覆盖已有的。
                do {
                    let containerDir = newContainer.isShared ? LCPath.lcGroupDataPath : LCPath.dataPath
                    let dst = newContainer.containerURL.appendingPathComponent("CZFKeychainImport.plist")
                    if !FileManager.default.fileExists(atPath: dst.path),
                       let entries = try? FileManager.default.contentsOfDirectory(at: containerDir, includingPropertiesForKeys: nil) {
                        // 3.8.562（L93）：先找本 App 旧容器（dataUUID
                        // 还是旧值，下面才改成 newName）里的排队文件
                        // 再拷——Data/Application 是全部 App 的容器
                        // 共用目录，原来取目录序第一个带 plist 的文件
                        // 夹，可能是别的 App 的排队文件，拷过来本 App
                        // 自己的那份就被 break 跳过、登录回不来；
                        // 旧 dataUUID 对不上（全新安装等）时才回落
                        // 到原来的第一个，3.8.377 的覆盖面不变。
                        let oldUUID = appInfo.dataUUID ?? ""
                        var fallbackSrc: URL?
                        var copied = false
                        for entry in entries where entry.lastPathComponent != newName {
                            let src = entry.appendingPathComponent("CZFKeychainImport.plist")
                            guard FileManager.default.fileExists(atPath: src.path) else { continue }
                            if !oldUUID.isEmpty, entry.lastPathComponent == oldUUID {
                                // 3.8.543（L159）：拷成了才记 copied、才 break——
                                // 原来 try? 吞掉失败还照记 copied = true、break，
                                // fallback 也被堵死：旧容器那份拷失败（读不出）时
                                // 别的容器那份明明能拷，登录排队文件却悄悄丢了。
                                // 失败就 continue，继续扫 fallback，不把失败那
                                // 份记成 fallback（再拷它一次也是白拷）。
                                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                                    copied = true
                                    break
                                }
                                continue
                            }
                            if fallbackSrc == nil { fallbackSrc = src }
                        }
                        if !copied, let fallbackSrc {
                            try? FileManager.default.copyItem(at: fallbackSrc, to: dst)
                        }
                    }
                }
                appInfo.dataUUID = newName
                uiDefaultDataFolder = newName
            }
            czfIsolateMultiOpenContainersIfNeeded()
            if let containerFolderName {
                uiSelectedContainer = uiContainers.first { $0.folderName == containerFolderName } ?? uiSelectedContainer
            }
            // 拆分只做一次、且只在最终选中定下来后做（容器越生越多根因之一）：
            // 原来选前先拆一次、选后再拆一次，面板传 dataUUID 时若选前已是
            // 共享容器，第一次拆出的新容器会被随后的指定选中覆盖、直接成
            // 孤儿留在列表里，第二次又拆一个——一次启动多两个容器。
            // 只留这一次：containerFolderName 为空时选中没变，等同于原来
            // 的第一次；指定了容器时拆的就是最终那个，不造孤儿。
            // 拆完选中已是新容器，当前文件夹就以选中为准，不再
            // 用旧的 containerFolderName，否则拆了也白拆。
            czfSplitSharedContainerIfNeeded()
        }
        // 3.8.545（L75）：本函数是非隔离 async，横幅卡/面板/App 页的裸 Task 调来（L32 注释）；下面各点读 @Published/_info 全在裸 Task 执行器上，L32 只包了容器准备段——逐点回主线程取当前值（L74-1 同款）。
        let currentDataFolder = await MainActor.run { uiSelectedContainer?.folderName }
        
        // 3.8.545（L75）：defaultClassicMode 读 _info 缓存、未命中还写 _info + save（LCAppInfo.m:672），shouldLaunchInMultitaskMode 读 @Published uiIsMultitaskModeSpecificed；逐点取。
        let classicMode = await MainActor.run { appInfo.defaultClassicMode }
        // 3.8.534 修法：await 不能出现在 ?? 右侧（非赋值运算符后），且 ?? 右侧
        // 的 MainActor.run 闭包是不支持并发的 autoclosure 上下文；拆成语句，
        // 先判再取——classicMode==0 且未传 multitask 时才回主线程读，语义不变。
        let resolvedMultitask: Bool
        if classicMode == 0 {
            if let existingMultitask = multitask {
                resolvedMultitask = existingMultitask
            } else {
                resolvedMultitask = await MainActor.run { shouldLaunchInMultitaskMode }
            }
        } else {
            resolvedMultitask = false
        }
        let multitask = resolvedMultitask
        
        if MultitaskManager.isMultitasking() || multitask,
           let currentDataFolder {
            if await bringExistingMultitaskWindowIfNeeded(dataUUID: currentDataFolder, urlScheme: urlStr) {
                return
            }
            
        }
        
        // this is rerouted to bringing app to front, so not needed here?
//        if(MultitaskManager.isUsing(container: uiSelectedContainer!.folderName)) {
//            throw "lc.container.inUse".loc + "\n MultiTask"
//        }
        
        // if the selected container is in use (either other lc or multitask), open the host lc associated with it
        // 3.8.545（L75）：逐点取当前值（同 :873 注释）。
        let launchContainerFolderName = await MainActor.run { uiSelectedContainer?.folderName }
        if
            let fn = launchContainerFolderName,
            var runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: fn)
        {
            runningLC = (runningLC as NSString).deletingPathExtension
            
            var openURLComp = URLComponents()
            openURLComp.scheme = runningLC
            if let urlStr {
                openURLComp.host = "open-url"
                openURLComp.queryItems = [
                    URLQueryItem(name: "url", value: Data(urlStr.utf8).base64EncodedString())
                ]
            }
            // 3.8.494（L13）：containerLock 里 runningLC 若是空串/
            // 非法 scheme（plist 损坏），URLComponents.url 会是
            // nil——原来两处 url! 直接闪退。拼不出就当没这条
            // 交接路，往下走正常启动。
            if let openURL = openURLComp.url, await UIApplication.shared.canOpenURL(openURL) {
                await UIApplication.shared.open(openURL)
                return
            }
        }
        
        // find a free lc to run non-multitasking shared app. If none, ask user if they want to terminate all multitasking apps
        if MultitaskManager.isMultitasking() && !multitask {
            // 3.8.545（L75）：uiIsShared 是 @Published，逐点取当前值。
            let launchIsShared = await MainActor.run { self.uiIsShared }
            if launchIsShared {
                var freeScheme: String? = nil
                LCUtils.forEachInstalledLC(isFree: true) { scheme, shouldBreak in
                    freeScheme = scheme
                    shouldBreak = true
                }
                if let freeScheme {
                    // 3.8.545（L75）：同 :873；本块内两处读的是同一次交接的同一个容器，一次取齐（中间无 await）。
                    let handoverFolderName = await MainActor.run { uiSelectedContainer?.folderName }
                    LCUtils.appGroupUserDefault.set(freeScheme, forKey: "LCLaunchExtensionScheme")
                    LCUtils.appGroupUserDefault.set(self.appInfo.relativeBundlePath, forKey: "LCLaunchExtensionBundleID")
                    LCUtils.appGroupUserDefault.set(handoverFolderName, forKey: "LCLaunchExtensionContainerName")
                    if let urlStr {
                        LCUtils.appGroupUserDefault.set(urlStr, forKey: "LCLaunchExtensionLaunchURL")
                    }
                    LCUtils.appGroupUserDefault.set(Date.now, forKey: "LCLaunchExtensionLaunchDate")
                    var launchURLComp = URLComponents()
                    launchURLComp.scheme = freeScheme
                    launchURLComp.host = "livecontainer-launch"
                    var queryItems: [URLQueryItem] = []
                    if let bundlePath = self.appInfo.relativeBundlePath {
                        queryItems.append(URLQueryItem(name: "bundle-name", value: bundlePath))
                    }
                    if let folderName = handoverFolderName {
                        queryItems.append(URLQueryItem(name: "container-folder-name", value: folderName))
                    }
                    
                    launchURLComp.queryItems = queryItems
                    
                    if let url = launchURLComp.url {
                        await UIApplication.shared.open(url)
                    } else {
                        throw "Unable to build URL from launchURLComp???"
                    }
                    return
                }
            }
            
            guard let ans = await delegate?.showRunWhenMultitaskAlert(), ans else {
                return
            }
        }
        
        await MainActor.run {
            isAppRunning = true
        }
        // 3.8.547（L77）：复位必须在放启动锁之前同步完成——原来 defer 里是 Task { await MainActor.run }：锁的 defer 注册在先、后执行，先放了，复位 Task 可能还没跑到；这时用户立刻再点启动，新 runApp 抢到锁、入口读到仍为 true 的 isAppRunning 就静默返回，点了没反应、再点一次才行（启动失败/取消后立刻重点的真窗口）。同步复位（主线程直写、后台 main.sync，isMainThread 防自死锁，L70/L73 同款）；defer 按注册逆序跑，本 defer 先跑、放锁后跑，放锁时 isAppRunning 已是 false。正常走完时末尾 MainActor.run 已复位过一次，再写一次 false 无害。
        defer {
            if Thread.isMainThread {
                isAppRunning = false
            } else {
                DispatchQueue.main.sync { isAppRunning = false }
            }
        }
        // 单 App VPN 快开（小火箭式）：核心启动与签名并行——
        // 两者无依赖（签名动插件文件、核心只碰 libXray），串
        // 行等是白白加起来的秒数。核心启动是同步阻塞的
        // CGoInvoke，放 detached 后台线程跑，不冻主线程；
        // 游客仍等核心就绪才起（免得头几秒走直连），只是
        // 不再串行等签名。签名失败时核心照常起着（等同预
        // 热），闲置后自动停；核心起失败也不拦启动（游客侧
        // fail-open 兜底，直连）。appInfo 先提成本地常量：
        // detached 闭包是 escaping，不能隐式抓 self 的属性。
        let vpnAppInfo = appInfo
        let vpnCoreTask: Task<Void, Never>? = CZFVPNManager.isEnabled(for: vpnAppInfo)
            ? Task.detached(priority: .userInitiated) { CZFVPNManager.shared.ensureRunning(for: vpnAppInfo) }
            : nil
        try await signApp(force: false)
        await vpnCoreTask?.value
        // P1（3.8.279）：探节点与开窗并行——277 是“探通再放行”，
        // 探的 0.2–0.5 秒（坏节点数秒）全堵在开窗前。改核心起来
        // 立刻开窗，探节点放后台并行跑；探通什么都不做，探不通
        // 后台切节点（切节点逻辑现成）。代价：坏节点时头 1 秒左
        // 右可能走 fail-open 直连（用户 2026-11-05 点头）。
        // 没标 VPN 的 App（vpnCoreTask 为 nil）不探。
        if vpnCoreTask != nil {
            Task.detached(priority: .userInitiated) {
                _ = await CZFVPNManager.shared.waitUntilNodeReady(for: vpnAppInfo, timeout: 5)
            }
        }

        // 3.8.545（L75）：isJITNeeded 读 _info（LCAppInfo.m:634）；is32bit 是 init 后不变的 bool ivar，顺手同跳取。
        var jitNeeded = await MainActor.run { appInfo.isJITNeeded || appInfo.is32bit }
        if let forceJIT {
            jitNeeded = forceJIT
        }
#if targetEnvironment(simulator)
        jitNeeded = false
#endif
        // 跳错修复：非多任务 JIT 的启动键不在这里写，改由
        // delegate 在 JIT 确认后写（见 jitLaunch(withScript:)）；
        // 多任务 JIT 与非 JIT 路仍在这里写（客启动在即，
        // 无 pending 窗口；多任务 JIT 键时序一字不动）。
        // delegate 路 = jitNeeded 且不走多任务 JIT 分支。
        let jitDefersKeyWrite: Bool
        if #available(iOS 17.4, *) {
            jitDefersKeyWrite = jitNeeded && !multitask
        } else {
            jitDefersKeyWrite = jitNeeded
        }
        // 串行门（多任务路）：启动键是全局单键（selected/
        // selectedContainer），亚秒级连点两次多任务启动会把第
        // 一次的键顶掉、客读到第二次的键而起错 App。写键前先
        // 持门，客窗口出现（dockManager.apps 含本容器，与
        // smallWindowOpenApp 认同一信号）或启动失败/15 秒超时
        // 才释放；第二次启动绝不挂到超时（拿门最多等 60 秒，
        // 仍拿不到就无门放行、不抛错）。经典路不动——宿主启动
        // 调用后即 SIGKILL，无门可持；delegate 写键路（非多任
        // 务 JIT）也不持门，键时序一字不动。
        // 本次是否走这里写键并起多任务窗的两条路（与下面
        // launch 分支一一对应）：17.4+ 时 multitask 即是；
        // 17.4 以下时 multitask 且非 JIT 才是（multitask+JIT
        // 走 delegate 路，键不在这里写，不持门）。
        let czfMultitaskLaunchHere: Bool
        if #available(iOS 17.4, *) {
            czfMultitaskLaunchHere = multitask
        } else if #available(iOS 16.0, *) {
            czfMultitaskLaunchHere = multitask && !jitNeeded
        } else {
            czfMultitaskLaunchHere = false
        }
        var czfGateHeld = false
        var czfGateUUID: String?
        // 3.8.545（L75）：逐点取当前值——门按这个容器号认，取号与持门之间无 await，不会错位。
        let gateFolderName = await MainActor.run { uiSelectedContainer?.folderName }
        if czfMultitaskLaunchHere, let folderName = gateFolderName {
            czfGateHeld = try await CZFMultitaskLaunchGate.shared.acquire(for: folderName)
            if czfGateHeld {
                czfGateUUID = folderName
            }
        }
        // 失败释放：链路抛错会跳过下面的交接，门还在手里时由
        // 这个 defer 放掉；成功交接后 czfGateUUID 已置空，
        // defer 不再动手。defer 里不能 await，用 Task 送释放。
        defer {
            if let uuid = czfGateUUID {
                Task {
                    await CZFMultitaskLaunchGate.shared.release(for: uuid)
                }
            }
        }
        if !jitDefersKeyWrite {
            if let bundleIdOverride {
                UserDefaults.standard.set(bundleIdOverride, forKey: "selected")
            } else {
                UserDefaults.standard.set(self.appInfo.relativeBundlePath, forKey: "selected")
            }
            if let urlStr {
                UserDefaults.standard.setValue(urlStr, forKey: "launchAppUrlScheme")
            }
            // 3.8.545（L75）：逐点取当前值。
            let keyContainerFolder = await MainActor.run { uiSelectedContainer?.folderName }
            UserDefaults.standard.set(keyContainerFolder, forKey: "selectedContainer")
        }

        // 3.8.545（L75）：下面三路 launch 用的名字、脚本、容器是“本次启动”的身份——delegate 回调与门（:1035 已按容器号持门）都按启动时定下的那一份走，中途改名/切容器不应让同一路启动前后用两份身份；启动决策点一次取齐（displayName 读 _info，jitLaunchScriptJs 与 uiSelectedContainer 是 @Published）。
        // 3.8.534 修法：displayName() 是未标注 nullability 的 ObjC 方法，泛型推断
        // 下 launchDisplayName 成了 String?，jitLaunch(appName:) 要 String；
        // 本文件 :262/:306 同款位置都用 ?? "App" 兜底，照抄。
        let launchDisplayName = await MainActor.run { appInfo.displayName() ?? "App" }
        let launchJITScript = await MainActor.run { jitLaunchScriptJs }
        let launchContainerFolder = await MainActor.run { uiSelectedContainer?.folderName }
        // 3.8.580（L111）：经典启动的 MetalANGLE 预载文件只在带框架时写，
        // 失败启动后宿主还活着、文件残留，下次经典启动的客会 dlopen 到
        // 上一个 App 的框架——main.c 读一行 dlopen 一行、读完才删
        //（LiveContainer/main.c:18-35），而 launchToGuestApp 失败时宿主
        // 不死（LCSharedUtils.m:155-161 注释）。本次非多任务即经典客
        //（JIT 经典路也经 delegate 走 launchToGuestApp）：带框架就原子
        // 写（防宿主 SIGKILL 在写一半时把文件撕成半截路径），不带就删
        // 残留；多任务客不走 main.c（同进程开窗，LCUtils.m:59），不动。
        // 原来这段只在下面经典 else 分支里、JIT 经典路根本不写，挪到
        // 分发前三路共用。
        if !multitask, #available(iOS 26.0, *) {
            let preloadURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("preloadLibraries.txt")
            if FileManager.default.fileExists(atPath: "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE") {
                let fileContents = "\(appInfo.bundlePath()!)/Frameworks/MetalANGLE.framework/MetalANGLE".data(using: .utf8)
                try fileContents?.write(to: preloadURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: preloadURL)
            }
        }
        // JIT 确认取消时不盖“最近启动”：delegate 的 jitLaunch 返 Bool，
        // 取消返 false；其它路（多任务/直接启动）照常盖戳。
        var czfDidLaunch = true
        if jitNeeded {
            if multitask, #available(iOS 17.4, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    // 3.8.496（L12）：启动窗在客端初始化完成前被关掉时 pid
                    // 回调永不触发——terminate 在未运行时是空操作，不走
                    // delegate；pidCallbacks 只在 onAppInitialize 里取走
                    // 调一次，无超时、无清理。continuation 永远挂起、
                    // isAppRunning 一直 true、App 再也点不开，只能重启
                    // LiveContainer。30 秒超时兜底，只恢复一次
                    //（CZFOnceBox，czfWaitForWindowAndRelease 同款；
                    // 3.8.545（L165）：take() 自带 NSLock 互斥，不再
                    // 依赖“回调都在主线程”的口头约定——多任务窗口
                    // 路 pidCallback 的线程本仓验不到、L101 分支成
                    // 功路也没包 MainActor.run，边界那一微秒双读
                    // 到 taken == false 就会双恢复闪退）。
                    let czfPidBox = CZFOnceBox()
                    let czfPidTimeout = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        if czfPidBox.take() {
                            continuation.resume(throwing: "Guest app did not initialize in 30 seconds")
                        }
                    }
                    LCUtils.launchMultitaskGuestApp(launchDisplayName) { pidNumber, error in
                        if let error {
                            czfPidTimeout.cancel()
                            if czfPidBox.take() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        guard let pidNumber = pidNumber else {
                            czfPidTimeout.cancel()
                            if czfPidBox.take() {
                                continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                            }
                            return
                        }
                        Task {
                            if let scriptData = launchJITScript, !scriptData.isEmpty {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: scriptData, appName: launchDisplayName)
                            } else {
                                await self.delegate?.jitLaunch(withPID: pidNumber.intValue, withScript: nil, appName: launchDisplayName)
                            }
                            czfPidTimeout.cancel()
                            await MainActor.run {
                                if czfPidBox.take() {
                                    continuation.resume()
                                }
                            }
                        }
                    }
                }
            } else {
                // Non-multitask JIT：启动键由 delegate 在 JIT 确认后写
                // （见 jitLaunch(withScript:)），这里只传值不写键；
                // bundleIdOverride 为空时退回自身包路径，与旧写键一致。
                if let scriptData = launchJITScript, !scriptData.isEmpty {
                    czfDidLaunch = await delegate?.jitLaunch(withScript: scriptData, appName: launchDisplayName, classicMode: classicMode, selectedBundlePath: bundleIdOverride ?? self.appInfo.relativeBundlePath, selectedContainerFolder: launchContainerFolder, launchURL: urlStr) ?? false
                } else {
                    czfDidLaunch = await delegate?.jitLaunch(appName: launchDisplayName, classicMode: classicMode, selectedBundlePath: bundleIdOverride ?? self.appInfo.relativeBundlePath, selectedContainerFolder: launchContainerFolder, launchURL: urlStr) ?? false
                }
            }
        } else if multitask, #available(iOS 16.0, *) {
            // 3.8.570（L101）：L12 只给 JIT 分支加了 30 秒超时兜底，
            // 非 JIT 多任务分支还是裸 try await——启动窗在客端初始
            // 化完成前被关掉时 pid 回调同样永不触发（同款机制：
            // terminate 在未运行时是空操作，不走 delegate；
            // pidCallbacks 只在 onAppInitialize 里取走调一次），
            // runApp 永远挂起、isAppRunning 与启动锁一直占着，
            // App 再也点不开，只能重启 LiveContainer。照 JIT 分支
            // 同款包一层 continuation + CZFOnceBox + 30 秒超时。
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let czfPidBox = CZFOnceBox()
                let czfPidTimeout = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if czfPidBox.take() {
                        continuation.resume(throwing: "Guest app did not initialize in 30 seconds")
                    }
                }
                LCUtils.launchMultitaskGuestApp(launchDisplayName) { pidNumber, error in
                    if let error {
                        czfPidTimeout.cancel()
                        if czfPidBox.take() {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard pidNumber != nil else {
                        czfPidTimeout.cancel()
                        if czfPidBox.take() {
                            continuation.resume(throwing: "Failed to obtain PID from LiveProcess")
                        }
                        return
                    }
                    czfPidTimeout.cancel()
                    if czfPidBox.take() {
                        continuation.resume()
                    }
                }
            }
        } else {
            LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)
        }

        // 启动成功：门交接给等窗任务——客窗口出现或 15 秒超时
        // 才释放；runApp 本身不等窗返回，isAppRunning 周期不变。
        if czfGateHeld, let uuid = czfGateUUID {
            czfGateUUID = nil
            Task.detached {
                await CZFMultitaskLaunchGate.shared.czfWaitForWindowAndRelease(uuid: uuid)
            }
        }

        // Record the launch time
        // JIT 确认取消时不盖（czfDidLaunch 为 false），免得“最近启动”
        // 排一个根本没启动的 App；其它路照常盖。
        // 3.8.542（L72）：原来这行写在裸 Task 执行器上——lastLaunched
        // 的 setter 改的是 LCAppInfo 的 NSMutableDictionary（_info，
        // LCAppInfo.m:1022-1023），NSMutableDictionary 不是线程安全
        // 的；主线程正同时读同一份字典（最近启动排序
        // LCAppSortManager:292、设置页显示、MultitaskAppWindow:279
        // 的 MainActor.run 内读），读-写并发可能崩。runApp 里另两
        // 处 appInfo 写（containers/dataUUID）早已在 L32 的
        // MainActor.run 块内，只剩这一处漏网；并进下面已有的
        // MainActor.run，一行不增、语义不变。
        await MainActor.run {
            if czfDidLaunch {
                appInfo.lastLaunched = Date()
            }
            isAppRunning = false
        }
    }
    
    func forceResign() async throws {
        // 3.8.526（L53）：跟 runApp 抢同一把启动锁——原来只凭
        // isAppRunning 守卫，置位在 await MainActor.run 之后、
        // 检查与置位之间有 await 间隙：连点两次“强制重新签名”
        // 会双双越过守卫、两个 signApp(force: true) 并发跑
        // patchExecAndSignIfNeed（3.8.459 审计修 runApp 双起
        // 用的就是这把锁，forceResign 没走它）；runApp 起手
        // 容器准备段还没置 isAppRunning 时点强制重签也会撞上。
        // 两路并发改同一份可执行文件（先拷备份、删主程序、挪
        // 回、再 zsign），后起的那路可能拷到半签的二进制、删
        // 掉正在签的文件，签出来是坏签名、App 点不开，只能再
        // 签一次。抢锁失败就静默返回，与原来 isAppRunning 守
        // 卫的行为一致（按钮本身也按 isAppRunning 置灰）。
        guard czfClaimLaunch() else {
            return
        }
        defer { czfReleaseLaunch() }
        // 3.8.547（L77）：同 runApp 入口——isAppRunning 是 @Published，裸 Task 执行器上读是 L69/L70 同款；回主线程读。
        if await MainActor.run(body: { isAppRunning }) {
            return
        }
        // 3.8.509（L31）：forceResign 是非隔离 async 方法，await 进来
        // 时已跳出主 actor——isAppRunning 是 @Published，直接写会离
        // 主线程发更新；设置页“强制重新签名”按钮的 disabled 读它，
        // 更新丢了按钮就不灰、点启动会撞上正在签名的 App。照 runApp
        // 同款用 MainActor.run 包住（defer 里重置早已是这写法）。
        await MainActor.run {
            isAppRunning = true
        }
        // 3.8.547（L77）：同 runApp——复位必须在放启动锁之前同步完成（见 runApp 处注释）；signApp 抛错时走同一窗口。
        defer {
            if Thread.isMainThread {
                self.isAppRunning = false
            } else {
                DispatchQueue.main.sync { self.isAppRunning = false }
            }
        }
        try await signApp(force: true)
    }
    
    func signApp(force: Bool = false) async throws {
        var signError : String? = nil
        var signSuccess = false
        defer {
            Task{ await MainActor.run {
                self.isSigningInProgress = false
            }}
        }
        
        // 3.8.499（L18）：启动路签名 continuation 加 5 分钟超时兜底——
        // 与安装路（LCAppListView:2629）同款：patchExecAndSignIfNeed
        // 回调一直不来时原来永远挂起，runApp 永不返、isAppRunning 一直
        // true、App 再也点不开（L12-1 JIT 超时同款）。超时与正常完成
        // 用 CZFOnceFlag 互斥，resume 只调一次；超时后走下面原有的
        // 失败路径（signError 非空、signSuccess 为 false）。
        let czfSignResumeOnce = CZFOnceFlag()
        var czfSignTimeoutTask: Task<Void, Never>?
        await withUnsafeContinuation({ c in
            czfSignTimeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if czfSignResumeOnce.claimTimeout() {
                    c.resume()
                }
            }
            appInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                if czfSignResumeOnce.claim() {
                    signError = error;
                    signSuccess = success;
                    c.resume()
                }
            }, progressHandler: { signProgress in
                guard let signProgress else {
                    return
                }
                // 3.8.509（L31）：progressHandler 是 ObjC 回调，LCAppInfo.m
                // 里直接调、没 dispatch 到主线程（completionHandler 那路
                // 有）；signApp 本身是非隔离 async，await 进来已离主
                // actor。isSigningInProgress 是 @Published，直接写会
                // 报“Publishing changes from background threads”、横
                // 幅签名指示可能不刷新——L28 网页回调同款。照本函数
                // defer 与下面 signTweaks 两处同款，用 Task + MainActor.run 包住。
                Task{ await MainActor.run {
                    self.isSigningInProgress = true
                } }
                // 3.8.499（L18）：KVO 闭包原来强抓 self 与 signProgress——
                // self → observer token → 闭包 → self 是永久循环引用，
                // 且闭包强留 Progress、观察永远等不到被观察对象释放，
                // 循环到不了自解；每次启动都签一次，卸掉的 App 的模型
                // 永远不释放。改 [weak self] + 用回调给的 p 读进度。
                self.observer = signProgress.observe(\.fractionCompleted) { [weak self] p, _ in
                    let fraction = p.fractionCompleted
                    DispatchQueue.main.async {
                        self?.signProgress = fraction
                    }
                }
            }, forceSign: force)
        })
        czfSignTimeoutTask?.cancel()
        if czfSignResumeOnce.timedOut {
            signError = "签名超时（已等待 5 分钟），请重试"
            signSuccess = false
        }
        // 签名已结束（正常完成或超时），进度观察不再需要，放掉 token。
        self.observer = nil
        if let signError {
            if !signSuccess {
                throw signError.loc
            }
        }
        
        // 先签全局插件（原顺序在 guard 之后，没选模块文件夹的 App 会提前返回、全局插件签不上）
        try await LCUtils.signTweaks(tweakFolderUrl: LCPath.tweakPath, force: force) { p in
            Task{ await MainActor.run {
                self.isSigningInProgress = true
            }}
        }

        // 单 App VPN（验证版）：开着 VPN 又没选 CZFVPN 目录的，
        // 把它加进模块文件夹列表，重定向插件才有地方部署
        // 3.8.545（L75）：signApp 走 runApp/forceResign 的裸 Task 执行器；tweakFolder 读/写 _info（LCAppInfo.m:218），isEnabled 那路经 L75-2 的 helper 已回主线程取 bundleId；读-改-写合进同一跳，中间插不进别的写。
        if CZFVPNManager.isEnabled(for: appInfo) {
            await MainActor.run {
                var folders = Self.czfSplitTweakFolders(appInfo.tweakFolder)
                if !folders.contains("CZFVPN") {
                    folders.append("CZFVPN")
                    appInfo.tweakFolder = Self.czfJoinTweakFolders(folders)
                }
            }
        }

        // 证书缺失时不再静默放行：没证书就签不了任何插件，
        // signTweaks 顶层 guard 会直接 return，游客照常启动、
        // 插件用旧签名加载必弹 Failed to load tweaks——
        // 2026-10-24 全量弹窗的根因就是证书丢了之后这里一直
        // 静默放行（钥匙串桥签名三版一模一样，证明机上签名
        // 根本没跑过）。有插件要签却没证书时直接报错，让用户
        // 去设置里重导证书，而不是放进游客弹看不懂的错。
        // 没插件的游客、禁注入的游客不受影响，照常启动。
        // 3.8.545（L75）：dontInjectTweakLoader/tweakFolder 读 _info，isShared 是设置页可改的 plain 属性（L74-1 同款）；本块一次取齐。
        let (certDontInject, certTweakFolders, certIsShared) = await MainActor.run {
            (appInfo.dontInjectTweakLoader, Self.czfSplitTweakFolders(appInfo.tweakFolder), appInfo.isShared)
        }
        if !certDontInject,
           LCSharedUtils.certificatePassword() == nil || LCUtils.certificateData() == nil {
            let fm = FileManager.default
            func folderHasTweak(_ url: URL) -> Bool {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
                for case let u as URL in e {
                    if u.pathExtension == "dylib" || u.pathExtension == "framework" { return true }
                }
                return false
            }
            var hasTweaks = folderHasTweak(LCPath.tweakPath)
            if !hasTweaks {
                for f in certTweakFolders {
                    let u = certIsShared ? LCPath.lcGroupTweakPath.appendingPathComponent(f) : LCPath.tweakPath.appendingPathComponent(f)
                    if folderHasTweak(u) { hasTweaks = true; break }
                }
            }
            if hasTweaks {
                throw "证书缺失，插件无法签名：请到设置 → 证书里重新导入证书，再打开 App"
            }
        }

        // 逐个签所选的模块文件夹（多选；一个没选就直接收尾，
        // 和旧版 guard 返回等价）
        // 3.8.545（L75）：上面全局插件签名是 await，tweakFolder 可能已变；进循环前现取（L74-1 逐点取当前值同款）。
        let (signTweakFolders, signIsShared) = await MainActor.run {
            (Self.czfSplitTweakFolders(appInfo.tweakFolder), appInfo.isShared)
        }
        for tweakFolder in signTweakFolders {
            let tweakFolderUrl: URL
            if signIsShared {
                tweakFolderUrl = LCPath.lcGroupTweakPath.appendingPathComponent(tweakFolder)
            } else {
                tweakFolderUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
            }
            // 自愈：转共享时没搬过来的旧文件夹（以前整串当一个路径搬，
            // 多选时直接失败），重开 App 时顺手搬过去，不然共享 App
            // 永远读不到它，重新开也没用。目标已存在时不动，不覆盖。
            if signIsShared {
                let privateUrl = LCPath.tweakPath.appendingPathComponent(tweakFolder)
                let fm = FileManager.default
                if !fm.fileExists(atPath: tweakFolderUrl.path),
                   fm.fileExists(atPath: privateUrl.path) {
                    try? fm.moveItem(at: privateUrl, to: tweakFolderUrl)
                }
            }
            // 单 App VPN（验证版）：签名之前按标记同步重定向插件。
            // 刚换上的新插件单独补一签（照手势插件的部署法）：批量
            // 签名带指纹缓存，新文件有被误判"已验过"跳过的先例
            // （真机出过签名无效被拒载），单独签没有缓存判断、必签。
            if tweakFolder == "CZFVPN", CZFVPNManager.syncProxyTweak(for: appInfo, tweakFolderUrl: tweakFolderUrl) {
                let proxyUrl = tweakFolderUrl.appendingPathComponent("CZFProxy.dylib")
                try? await LCUtils.signSingleTweakFile(proxyUrl)
                if !checkCodeSignature((proxyUrl.path as NSString).utf8String) {
                    // 第一签验不过就再签一次（下面的批量签名还会再兜底）
                    try? await LCUtils.signSingleTweakFile(proxyUrl)
                }
            }
            try await LCUtils.signTweaks(tweakFolderUrl: tweakFolderUrl, force: force) { p in
                Task{ await MainActor.run {
                    self.isSigningInProgress = true
                }}
            }
        }
    }

    func setLocked(newLockState: Bool) async {
        // 3.8.544（L74）：三路调用方全是裸 Task（设置页 Toggle :599、横幅卡 :450、网格 :725），isLocked 读/写 _info + save（LCAppInfo.m:698-708），离主线程是 L72-2 同款；入口现取。
        let currentlyLocked = await MainActor.run { appInfo.isLocked }
        // if locked state in appinfo already match with the new state, we just the change
        if currentlyLocked == newLockState {
            return
        }
        
        if newLockState {
            // 3.8.520（L46）：成功加锁也要同步 uiIsLocked——横幅卡
            // 菜单（BannerVC:450）与网格（CZFAppGridView:725）直接调
            // setLocked，不经过设置页 Toggle 的绑定写点；不同步时
            // uiIsLocked 一直是旧值，横幅锁徽标（BannerVC:232）与
            // 设置页开关（LCAppSettingsView:592/602/625）都显示错，
            // 直到下次 dock 变化或卡片重建才刷回来。设置页那路
            // Toggle 已先写过同值，再写一次无害。
            // 3.8.544（L74）：appInfo.isLocked 写 _info + save，合进同一跳。
            await MainActor.run {
                appInfo.isLocked = true
                uiIsLocked = true
            }
        } else {
            // authenticate before cancelling locked state
            // 3.8.441：解锁必须每次都弹人脸识别——原来调
            // LCUtils.authenticateUser()，隐藏 App 解锁过一次后
            // 它直接短路放行，锁定的 App 点“解锁”就不弹人脸了。
            // 改走强制认证（不短路、不碰隐藏解锁态）。
            do {
                let result = try await LCUtils.authenticateUserForced()
                if !result {
                    // 3.8.510（L32）：同 toggleHidden，横幅卡裸 Task 调
                    // setLocked 时不在主 actor 上，uiIsLocked 必须包住。
                    await MainActor.run { uiIsLocked = true }
                    return
                }
            } catch {
                await MainActor.run { uiIsLocked = true }
                return
            }
            
            // auth pass, we need to cancel app's lock and hidden state
            // 3.8.520（L46）：成功解锁同款同步 uiIsLocked，理由同上
            // （横幅卡/网格调 setLocked 时不走 Toggle 绑定）。
            // 3.8.544（L74）：appInfo.isLocked 写 _info + save、isHidden 读 _info，同上回主线程。
            await MainActor.run {
                appInfo.isLocked = false
                uiIsLocked = false
            }
            let hidden = await MainActor.run { appInfo.isHidden }
            if hidden {
                await toggleHidden()
            }
        }
    }
    
    func toggleHidden() async {
        // 3.8.510（L32）：整段放主 actor 上——LCAppBannerViewController
        // 是普通 UIViewController（非 @MainActor），它的 UIAction
        // 里裸 Task 调这里，uiIsHidden 直接写会离主线程发更新、
        // delegate 的 closeNavigationView 还会离主线程改 @State；
        // 其余调用方（网格/列表/设置页）都在主 actor 上，包一层无害。
        await MainActor.run {
            delegate?.closeNavigationView()
            if appInfo.isHidden {
                appInfo.isHidden = false
                uiIsHidden = false
            } else {
                appInfo.isHidden = true
                uiIsHidden = true
            }
            delegate?.changeAppVisibility(app: self)
        }
    }
    
    func loadSupportedLanguages() throws {
        let fm = FileManager.default
        if supportedLanguages != nil {
            return
        }
        supportedLanguages = []
        let fileURLs = try fm.contentsOfDirectory(at: URL(fileURLWithPath: appInfo.bundlePath()!) , includingPropertiesForKeys: nil)
        for fileURL in fileURLs {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let fileType = attributes[.type] as? FileAttributeType
            if(fileType == .typeDirectory && fileURL.lastPathComponent.hasSuffix(".lproj")) {
                supportedLanguages?.append(fileURL.deletingPathExtension().lastPathComponent)
            }
        }
        
    }
    
    private func bringExistingMultitaskWindowIfNeeded(dataUUID: String, urlScheme: String?) async -> Bool {
        guard #available(iOS 16.0, *) else { return false }
        return await MainActor.run {
            // 已有窗口必须属于本条目：同包名别的条目若共用容器，
            // 按 dataUUID 找会把别人的窗口顶回来；归属对不上
            // 就不顶，交给 runApp 去拆容器、起新窗口。
            if let dockApp = MultitaskDockManager.shared.apps.first(where: { $0.appUUID == dataUUID }) {
                // dock 条目存在却无法证明归属（appInfo 缺失或路径
                // 为空）时视为未知，一律不顶窗口，交给 runApp；
                // 宁可多起一个窗口，不顶错别人的。
                guard let dockPath = dockApp.appInfo?.relativeBundlePath, !dockPath.isEmpty else {
                    return false
                }
                if dockPath != appInfo.relativeBundlePath {
                    return false
                }
            }
            if let urlScheme {
                UserDefaults.standard.setValue(urlScheme, forKey: "launchAppUrlScheme")
            }
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: dataUUID)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: dataUUID)
            }
            if let urlScheme, !found  {
                UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            }
            return found
        }
    }
    
    static func copy(fromApp: LCAppModel, toAppInfo: LCAppInfo) {
        // copy previous configration to new app
        toAppInfo.autoSaveDisabled = true
        toAppInfo.isLocked = fromApp.appInfo.isLocked
        toAppInfo.isHidden = fromApp.appInfo.isHidden
        toAppInfo.isShared = fromApp.appInfo.isShared
        
        toAppInfo.containerInfo = fromApp.appInfo.containerInfo
        toAppInfo.tweakFolder = fromApp.appInfo.tweakFolder
        toAppInfo.dataUUID = fromApp.appInfo.dataUUID
        
        toAppInfo.spoofSDKVersion = fromApp.appInfo.spoofSDKVersion
        toAppInfo.doSymlinkInbox = fromApp.appInfo.doSymlinkInbox

        toAppInfo.selectedLanguage = fromApp.appInfo.selectedLanguage

        toAppInfo.orientationLock = fromApp.appInfo.orientationLock
        toAppInfo.dontInjectTweakLoader = fromApp.appInfo.dontInjectTweakLoader
        toAppInfo.hideLiveContainer = fromApp.appInfo.hideLiveContainer
        toAppInfo.dontLoadTweakLoader = fromApp.appInfo.dontLoadTweakLoader
        toAppInfo.doUseLCBundleId = fromApp.appInfo.doUseLCBundleId
        toAppInfo.fixFilePickerNew = fromApp.appInfo.fixFilePickerNew
        toAppInfo.fixLocalNotification = fromApp.appInfo.fixLocalNotification
        toAppInfo.fixBackgroundTaskIdentifiers = fromApp.appInfo.fixBackgroundTaskIdentifiers
        
        toAppInfo.isJITNeeded = fromApp.appInfo.isJITNeeded
        toAppInfo.jitLaunchScriptJs = fromApp.appInfo.jitLaunchScriptJs
        toAppInfo.helperProcessesSupport = fromApp.appInfo.helperProcessesSupport
        
        toAppInfo.multitaskSpecified = fromApp.appInfo.multitaskSpecified
        toAppInfo.classicMode = fromApp.appInfo.classicMode
        
        toAppInfo.lastLaunched = fromApp.appInfo.lastLaunched
        
        // 3.8.585（L117）：上游的 copy 漏了这三项用户配置，覆盖安装
        // 后全丢了——dontSign（设置页“不签名”，丢了下次启动会把用户
        // 设成不签名的 App 又签一遍）、remark（设置页备注）、
        // selected32BitEmulator（32 位模拟器选择，丢了回落全局默认；
        // 客启动时 LCBootstrap.m:690 先读它）。customDisplayName
        // 同款缺口在调用方补（LCAppListView:2911），这里三项直接
        // 补进 copy，之后别的调用方也不丢。
        toAppInfo.dontSign = fromApp.appInfo.dontSign
        toAppInfo.remark = fromApp.appInfo.remark
        toAppInfo.selected32BitEmulator = fromApp.appInfo.selected32BitEmulator

        toAppInfo.autoSaveDisabled = false
        toAppInfo.save()
    }
}

// MARK: - 多任务启动串行门（CZF，3.8.230）
// 启动键是全局单键，多任务路两次启动亚秒级连点会互相顶键、
// 客读错键起错 App。门是全局一把（不分容器——键本身就是
// 全局的）：写键前持门，客窗口出现或启动失败才放行。
// 取消：acquire 的检查与 sleep 在任务取消时抛错，门不落袋；
// 等待上限：持门等窗最多 15 秒、拿门最多 60 秒，超时即放
// 行/无门启动，第二次启动绝不无限挂起。
/// 只恢复一次的盒子（O-19）：窗口出现回调与 15 秒超时兜底
/// 都在主队列串行跑，谁先到谁拿，另一个空转；continuation
/// 只恢复一次，绝不 double-resume。
/// 3.8.545（L165）：take() 加 NSLock——原来是裸 Bool，
/// 全靠“回调两路都在主线程”的口头约定串行（L12 注释原话）：
/// 场景路回调确在主队列（DecoratedAppSceneViewController.m
/// :647 显式 dispatch 到 main），但多任务窗口路走
/// MultitaskWindowManager.openAppWindowWithDisplayName 的
/// pidCallback（仓外组件，本仓验不到它在哪个线程回调）、
/// 无 LiveProcess 的早错路在调用方线程同步回调、L101 非 JIT
/// 分支成功路直接在回调里 take()（没包 MainActor.run）——
/// 客初始化正好落在 30 秒超时边界那一微秒，两路同时读到
/// taken == false 就双恢复，CheckedContinuation 双 resume
/// 直接闪退（3.8.476 真机同款 EXC_BAD_ACCESS）。同仓已有
/// 带锁的双胞胎 CZFOnceFlag（LCAppListView.swift:49），照它
/// 同款加锁；调用方一字不动，串行路行为不变。
private final class CZFOnceBox {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}

actor CZFMultitaskLaunchGate {
    static let shared = CZFMultitaskLaunchGate()
    private var holder: String?
    // 3.8.551（L81）：等待者带每次 acquire 的唯一 token——原来只按
    // uuid 认，两个同 uuid 等待者时超时/取消按 uuid 找第一个会摘
    // 错人（见 acquire 处注释）；放门仍按队首交接，不变。
    private var waiters: [(token: UUID, uuid: String, continuation: CheckedContinuation<Bool, Error>)] = []
    // H-10 事件驱动等待队列：拿不到门时挂起等放门，不再 0.1 秒
    // 轮询。release/超时/取消三处都先把等待者移出队列再恢复，
    // 只恢复一次；release 时把门原子交给队首，醒来即持门。

    /// 拿门：无人持门直接拿；有人时挂起等放门或 60 秒超时；返回
    /// true = 已持门（调用方负责释放），false = 超时未拿到
    /// （无门放行，调用方不得释放）。任务取消时抛错。
    func acquire(for uuid: String) async throws -> Bool {
        try Task.checkCancellation()
        if holder == nil {
            holder = uuid
            return true
        }
        // 3.8.551（L81）：等待者按 uuid 认会摘错人——czfClaimLaunch
        // 注释已认同容器还会在门里挂两个同 uuid 等待者（两条目共用
        // 一容器）；后入队的取消时 cancelWaiter 按 uuid 找第一个，
        // 会把先入队的摘掉并以取消错恢复它（先入队的启动无故失败，
        // 后入队的还在队里挂到 60 秒超时）。等待者改按每次 acquire
        // 的唯一 token 认，超时/取消只动自己；放门仍按队首交接，不变。
        let token = UUID()
        // 超时任务：60 秒后把本等待者移出队列并以 false 恢复；
        // 拿到门/取消时在 defer 里取消它。
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                await self.timeoutWaiter(token: token)
            } catch {
                // 取消/已拿到门：什么都不做
            }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                // 闭包同步执行，还在 actor 隔离内，直接入队。
                waiters.append((token: token, uuid: uuid, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token) }
        }
    }

    /// 放门：只有持有者能放，别人的释放一律忽略（超时无门
    /// 放行的调用方、已交接的等窗任务都不会误清别人的门）。
    /// 有排队的直接把门交给队首（actor 内原子交接）。
    func release(for uuid: String) {
        if holder == uuid {
            holder = nil
            if let next = waiters.first {
                waiters.removeFirst()
                holder = next.uuid
                next.continuation.resume(returning: true)
            }
        }
    }

    /// 超时：本等待者还在队里就移出并以 false 恢复（已拿到门
    /// 的不在队里，什么都不做）。按 token 认，不按 uuid（见上）。
    private func timeoutWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    /// 取消：本等待者还在队里就移出并抛取消错（已恢复的不在
    /// 队里，什么都不做）。按 token 认，不按 uuid（见上）。
    private func cancelWaiter(token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 等窗后放门：客窗口出现（dock 条目追加）即放；15 秒
    /// 未出现也放——门绝不为一次慢启动/失败启动一直占着。
    /// O-19：原来每 0.3 秒在主线程认一次 dockManager.apps，
    /// 最长 15 秒（50 次唤醒）。改走 czfOnWindowAppeared 回调
    /// （MultitaskDockView 已有，出现先于注册的竞态由它开头
    /// 的已存在检查兜底）；它超时不调 handler，所以另起一个
    /// 15 秒 asyncAfter 兜底，超时也放门。出现/超时谁先到谁
    /// 恢复，CZFOnceBox 保证只恢复一次。
    func czfWaitForWindowAndRelease(uuid: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = CZFOnceBox()
            // MultitaskDockManager 带 @available(iOS 16.0, *)，跨文件
            // 引用必须包 #available（v170 血泪：不包编不过）；16 以下
            // 多任务根本不存在，不注册回调，只走下面 15 秒超时放门。
            if #available(iOS 16.0, *) {
                MultitaskDockManager.shared.czfOnWindowAppeared(uuid: uuid, timeout: 15) {
                    guard box.take() else { return }
                    continuation.resume()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                guard box.take() else { return }
                continuation.resume()
            }
        }
        release(for: uuid)
    }
}
