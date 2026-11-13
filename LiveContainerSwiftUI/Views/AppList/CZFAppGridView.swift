//  CZFAppGridView.swift
//  LiveContainerSwiftUI
//
//  App 列表网格模式（3.8.406）：LazyVGrid 大图标 + 名字，
//  列数/图标大小可调；点图标启动、长按出菜单（banner 大菜单的
//  SwiftUI 复刻）、多选模式挂勾选圈。运行中角标没有复用：banner
//  本身就没有运行角标（runControl 只显示签名进度、恒可点），
//  网格也不新发明一个。保存图标没复用：banner 用
//  UIDocumentPickerViewController 从 VC 弹出，SwiftUI 网格没有
//  可弹的 VC，见报告。

import SwiftUI
import UIKit

// O-13：图标加载异步化——body 只同步读内存/磁盘缓存（快路径），
// 磁盘未命中才到后台生成（generateIconForBundleURL + 写盘），
// 生成完回主线程调 completion；不改图标生成的实际逻辑
//（生成仍是原同步 iconIsDarkIcon，内部先重查内存/磁盘、
// 未命中才生成+写盘）。同一 App+明暗在途只生成一次：
// saveCGImage 是直写目标文件（IconServices.m:227），并发
// 写同一文件会互相损坏，须去重（锁 + 待回调用表，同款见
// LCUtilsExtensions.verifiedTweakFoldersLock）。
enum CZFAppIconLoader {
    private static let czfLock = NSLock()
    private static var czfPending: [String: [(UIImage?) -> Void]] = [:]

    private static func czfKey(for appInfo: LCAppInfo, darkModeIcon: Bool) -> String {
        appInfo.bundlePath() + (darkModeIcon ? "|dark" : "|light")
    }

    /// 只读内存/磁盘缓存，不生成图标。磁盘命中时同步返回并
    /// 写内存缓存（与 LCAppInfo.m:203-219 原版对称）。
    /// 磁盘文件名以 LCAppInfo.m:185-222 为准，别另发明。
    static func cachedIconOnly(for appInfo: LCAppInfo, darkModeIcon: Bool) -> UIImage? {
        if darkModeIcon {
            if let icon = appInfo.cachedIconDark { return icon }
        } else if let icon = appInfo.cachedIcon {
            return icon
        }
        if let builtin = appInfo as? BuiltInSideStoreAppInfo {
            return builtin.czfCachedIconOnly(isDarkIcon: darkModeIcon)
        }
        let fileName = darkModeIcon ? "LCAppIconDark.png" : "LCAppIconLight.png"
        let path = (appInfo.bundlePath() as NSString).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: path),
              let icon = UIImage(contentsOfFile: path) else { return nil }
        if darkModeIcon {
            appInfo.cachedIconDark = icon
        } else {
            appInfo.cachedIcon = icon
        }
        return icon
    }

    /// 后台生成图标；completion 一律回主线程。调用前请先走
    /// cachedIconOnly 快路径——已缓存的不要进这里。
    static func loadIconAsync(for appInfo: LCAppInfo, darkModeIcon: Bool, completion: @escaping (UIImage?) -> Void) {
        let key = czfKey(for: appInfo, darkModeIcon: darkModeIcon)
        czfLock.lock()
        if var list = czfPending[key] {
            list.append(completion)
            czfPending[key] = list
            czfLock.unlock()
            return
        }
        czfPending[key] = [completion]
        czfLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            // 生成逻辑不动：原同步方法内部先重查内存/磁盘，
            // 仍未命中才 generateIconForBundleURL + 写盘。
            let icon: UIImage? = appInfo.iconIsDarkIcon(darkModeIcon)
            DispatchQueue.main.async {
                czfLock.lock()
                let completions = czfPending.removeValue(forKey: key) ?? []
                czfLock.unlock()
                for pendingCompletion in completions {
                    pendingCompletion(icon)
                }
            }
        }
    }

    /// loadIconAsync 的 async/await 包装（供 cell 的 .task 用）。
    static func loadIcon(for appInfo: LCAppInfo, darkModeIcon: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            loadIconAsync(for: appInfo, darkModeIcon: darkModeIcon) { icon in
                continuation.resume(returning: icon)
            }
        }
    }
}

// 网格单元要调的一组动作：启动类走 LCAppListView 已有的方法，
// 删除/插件/VPN 等在 CZFAppGridView 里就地实现（见下）。
struct CZFAppGridActions {
    var isBatchSelected: (LCAppModel) -> Bool
    var onToggleBatchSelection: (LCAppModel) -> Void
    var onLaunch: (LCAppModel) -> Void
    var onLaunchMultitask: (LCAppModel) -> Void
    var onOpenSettings: (LCAppModel) -> Void
    // 下面三项由 CZFAppGridView 就地实现（删除确认框、VPN 开关、
    // 创建 App Clip），列表页传 actions 时不用填。
    var onDeleteRequest: (LCAppModel) -> Void = { _ in }
    var onToggleVPN: (LCAppModel) -> Void = { _ in }
    var onCreateAppClip: (LCAppModel) async -> Void = { _ in }
}

struct CZFAppGridView: View {
    var apps: [LCAppModel]
    var hiddenApps: [LCAppModel]
    var hiddenUnlocked: Bool
    var hiddenCount: Int
    var darkModeIcon: Bool
    var batchMode: Bool
    var columns: Int
    var iconSize: Int
    // 搜索中（3.8.428，设置审计 #28）：调用方传搜索是否有词；
    // 默认 false，老调用点不传也能编；有词时空态不显示安装提示。
    // LCAppListView 接线：isSearching: searchContext.debouncedQuery != ""
    var isSearching: Bool = false
    var actions: CZFAppGridActions
    var onRemoveApp: (LCAppModel) -> Void
    var onAuthenticateHidden: () -> Void
    var promptForGeneratedIconStyle: () async -> GeneratedIconStyle?
    var installMdm: (Data) -> Void

    @State private var czfGridDeleteTarget: LCAppModel?
    @State private var czfGridDeleteConfirm = false
    @State private var czfGridError: String?
    // 网格拖拽重排（3.8.453）：长按图标拖到另一个图标上松手即换位，
    // 复用列表模式的 LCAppReorderDropDelegate + 同款提交逻辑。
    // 搜索中（显示子集）与批量模式（点按是勾选）不挂拖拽，见下面。
    @State private var czfGridDragID: String?

    // 网格拖拽提交（3.8.453）：与 LCAppListView.commitDragReorder
    // 同款——按可见顺序重排 customSortOrder、切到自定义排序；
    // 隐藏 App 追加在尾巴，不丢位置。写 customSortOrder 即写回
    // App Group 并刷新设置备份（LCAppSortManager.didSet）。
    private func czfCommitGridDragReorder(draggedID: String, targetApp: LCAppModel) {
        defer { czfGridDragID = nil }
        guard !isSearching && !batchMode else { return }
        let manager = LCAppSortManager.shared
        // 可见顺序 = 网格现在显示的 apps（已按排序排好）；隐藏的
        // 追加在尾巴，与列表模式 commitDragReorder 同口径。
        var visibleIDs = apps.compactMap { manager.getUniqueIdentifier(for: $0) }
        guard let from = visibleIDs.firstIndex(of: draggedID),
              let targetID = manager.getUniqueIdentifier(for: targetApp),
              let to = visibleIDs.firstIndex(of: targetID), from != to else { return }
        visibleIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        var newOrder = visibleIDs
        for hidden in hiddenApps {
            guard let id = manager.getUniqueIdentifier(for: hidden), !newOrder.contains(id) else { continue }
            newOrder.append(id)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            manager.customSortOrder = newOrder
            manager.appSortType = .custom
        }
    }

    private var czfGridColumns: [GridItem] {
        let count = max(3, min(6, columns))
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: count)
    }

    // 图标尺寸：大/中/小 = 单元宽度的 1.0 / 0.85 / 0.7。
    private var czfIconFactor: CGFloat {
        switch iconSize {
        case 1: return 0.85
        case 2: return 0.7
        default: return 1.0
        }
    }

    private func czfCellActions() -> CZFAppGridActions {
        CZFAppGridActions(
            isBatchSelected: actions.isBatchSelected,
            onToggleBatchSelection: actions.onToggleBatchSelection,
            onLaunch: actions.onLaunch,
            onLaunchMultitask: actions.onLaunchMultitask,
            onOpenSettings: actions.onOpenSettings,
            onDeleteRequest: { app in
                czfGridDeleteTarget = app
                czfGridDeleteConfirm = true
            },
            onToggleVPN: { app in czfToggleVPN(for: app) },
            onCreateAppClip: { app in await czfCreateAppClip(for: app) }
        )
    }

    // 单 App VPN 开关（banner makeContextMenu 同款语义）：没开过
    // 就打标记并立刻启动这个 App；已开就摘标记。
    private func czfToggleVPN(for app: LCAppModel) {
        if CZFVPNManager.isEnabled(for: app.appInfo) {
            CZFVPNManager.setEnabled(false, for: app.appInfo)
        } else {
            CZFVPNManager.setEnabled(true, for: app.appInfo)
            actions.onLaunch(app)
        }
    }

    // 创建 App Clip（banner createAppClip 同款，只改错误出口）：
    // 风格先问 delegate，配好后走 delegate.installMdm。
    private func czfCreateAppClip(for app: LCAppModel) async {
        guard let style = await promptForGeneratedIconStyle() else { return }
        do {
            guard let profile = app.appInfo.generateWebClipConfig(
                withContainerId: app.uiSelectedContainer?.folderName,
                iconStyle: style
            ) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            installMdm(data)
        } catch {
            czfGridError = error.localizedDescription
        }
    }

    // 删 App 的文件部分走 banner 的共用静态方法（单个卸载与批量
    // 删除共用这一份）：删 .app 包、从列表移除、可选删数据容器
    // + 钥匙串；确认弹窗是本页的 SwiftUI confirmationDialog。
    private func czfDeleteGridApp(removeDataFolders: Bool) {
        guard let app = czfGridDeleteTarget else { return }
        czfGridDeleteTarget = nil
        do {
            let (failedContainers, keptBackupName) = try LCAppBannerViewController.deleteAppFiles(
                app,
                removeDataFolders: removeDataFolders,
                removeFromList: { model in onRemoveApp(model) }
            )
            var messages: [String] = []
            if !failedContainers.isEmpty {
                messages.append("以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))")
            }
            if let kept = keptBackupName {
                messages.append("备份「\(kept)」已锁定，已保留")
            }
            if !messages.isEmpty {
                czfGridError = messages.joined(separator: "\n")
            }
        } catch {
            czfGridError = error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: czfGridColumns, spacing: 12) {
            ForEach(apps, id: \.self) { app in
                CZFAppGridCell(
                    app: app,
                    iconFactor: czfIconFactor,
                    darkModeIcon: darkModeIcon,
                    batchMode: batchMode,
                    actions: czfCellActions()
                )
                // 网格拖拽重排（3.8.453）：长按图标拖到另一个图标上松手
                // 即换位，复用列表模式的 DropDelegate + 提交逻辑。
                // 搜索中（子集）与批量模式（点按是勾选）不挂拖拽。
                .onDrag {
                    guard !isSearching && !batchMode,
                          let id = LCAppSortManager.shared.getUniqueIdentifier(for: app) else {
                        return NSItemProvider()
                    }
                    czfGridDragID = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(of: [.text], delegate: LCAppReorderDropDelegate(
                    targetApp: app,
                    draggedID: { czfGridDragID },
                    commit: { dragged, target in czfCommitGridDragReorder(draggedID: dragged, targetApp: target) }
                ))
            }
            if hiddenUnlocked {
                ForEach(hiddenApps, id: \.self) { app in
                    CZFAppGridCell(
                        app: app,
                        iconFactor: czfIconFactor,
                        darkModeIcon: darkModeIcon,
                        batchMode: batchMode,
                        actions: czfCellActions()
                    )
                    .onDrag {
                        guard !isSearching && !batchMode,
                              let id = LCAppSortManager.shared.getUniqueIdentifier(for: app) else {
                            return NSItemProvider()
                        }
                        czfGridDragID = id
                        return NSItemProvider(object: id as NSString)
                    }
                    .onDrop(of: [.text], delegate: LCAppReorderDropDelegate(
                        targetApp: app,
                        draggedID: { czfGridDragID },
                        commit: { dragged, target in czfCommitGridDragReorder(draggedID: dragged, targetApp: target) }
                    ))
                }
            }
        }
        // 空态（3.8.428，设置审计 #28 / App 页 #2）：网格 0 个 App
        // 时原来只有搜索行、页面全空白；补列表模式同一句安装提示
        //（LCAppListView.swift:1182）。可见为空 = 可见 App 为空，
        // 且隐藏 App 未解锁或也为空；搜索有词时不显示。
        if apps.isEmpty && (!hiddenUnlocked || hiddenApps.isEmpty) && !isSearching {
            Text("lc.appList.installTip".loc)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        }
        // 未解锁时保留原来的透明长按区（人脸识别唤起），不要删。
        // 3.8.441（用户 13:07 令）：“解锁隐藏 App”按钮去掉，
        // 改成长按 App 页空白处显示隐藏 App——可见按钮会暴露
        // “这里藏了东西”，长按空白处才是隐蔽入口。透明长按
        // 区还在下面，点按不到、长按才弹人脸识别。
        if hiddenCount > 0 && !hiddenUnlocked {
            Color.clear
                .frame(height: LCAppBannerRootView.bannerHeight)
                .contentShape(Rectangle())
                // VoiceOver：透明区无标签、长按手势 VoiceOver 找不到；
                // 加标签与动作，调已有的人脸识别闭包。
                .accessibilityLabel("解锁隐藏 App")
                .accessibilityAction {
                    onAuthenticateHidden()
                }
                .onLongPressGesture {
                    onAuthenticateHidden()
                }
        }
        }
        .confirmationDialog("删除 App", isPresented: $czfGridDeleteConfirm, titleVisibility: .visible) {
            Button("删除 App（保留数据）", role: .destructive) {
                czfDeleteGridApp(removeDataFolders: false)
            }
            Button("删除 App 及其数据", role: .destructive) {
                czfDeleteGridApp(removeDataFolders: true)
            }
            Button("取消", role: .cancel) {
                czfGridDeleteTarget = nil
            }
        }
        .alert("提示", isPresented: Binding(get: { czfGridError != nil }, set: { if !$0 { czfGridError = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) {
            }
        } message: {
            Text(czfGridError ?? "")
        }
    }
}

// 格子点按手势（3.8.428，设置审计 #32 / App 页 #5）：批量与
// 非批量要挂的手势类型不同（普通单击 vs 双击优先），用具名
// ViewModifier 包一层分支——.gesture 一行只能是一种手势类型，
// 本仓零用法的 AnyGesture 不用。非批量保留双击优先（双击进
// 设置、单击启动）；批量只挂普通单击，直接勾选、不等双击超时。
private struct CZFAppGridTapGesture: ViewModifier {
    var batchMode: Bool
    var app: LCAppModel
    var actions: CZFAppGridActions

    @ViewBuilder
    func body(content: Content) -> some View {
        if batchMode {
            content.gesture(
                TapGesture(count: 1)
                    .onEnded {
                        actions.onToggleBatchSelection(app)
                    }
            )
        } else {
            content.gesture(
                TapGesture(count: 2)
                    .onEnded {
                        actions.onOpenSettings(app)
                    }
                    .exclusively(before: TapGesture(count: 1)
                        .onEnded {
                            actions.onLaunch(app)
                        })
            )
        }
    }
}

// 网格单元：大图标 + 下方单行名字。图标取法与 banner 同款
//（O-13：CZFAppIconLoader 快路径同步读缓存，未命中后台生成）。
// GeometryReader + aspectRatio(1) 让图标区成正方形，图标宽 =
// 单元宽 × 系数（最小 44），不依赖父视图量宽。
struct CZFAppGridCell: View {
    @ObservedObject var app: LCAppModel
    var iconFactor: CGFloat
    var darkModeIcon: Bool
    var batchMode: Bool
    var actions: CZFAppGridActions

    @State private var czfCellError: String?
    // O-13：后台生成的图标 + 它属于哪个 App/明暗；cell 复用
    // （滚动/明暗切换）后 key 对不上就不用，避免刷到别的 cell。
    @State private var czfLoadedIcon: UIImage?
    @State private var czfLoadedIconKey: String?
    // 设置 #37：App 名晕影按 colorScheme 换色——浅色白晕影、
    // 深色黑晕影（源格子 CZFSourceGridView.swift:316 同款）。
    @Environment(\.colorScheme) private var colorScheme

    // O-13：图标归属键——bundlePath 每个 App 唯一 + 明暗。
    private var czfCurrentIconKey: String {
        app.appInfo.bundlePath() + (darkModeIcon ? "|dark" : "|light")
    }

    // O-13：body 只同步读缓存——先看后台已生成的，再走
    // 内存/磁盘快路径；两处都没有才显示占位，后台任务补。
    private var czfResolvedIcon: UIImage? {
        if let loaded = czfLoadedIcon, czfLoadedIconKey == czfCurrentIconKey {
            return loaded
        }
        return CZFAppIconLoader.cachedIconOnly(for: app.appInfo, darkModeIcon: darkModeIcon)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                // 图标边长不小于 44，但不许超出单元格宽（小屏格子不足 44pt
                // 时原 max 会盖住相邻格子）；iconFactor 逻辑不动。
                let side = min(max(geo.size.width * iconFactor, 44), geo.size.width)
                // 图标缺失占位（3.8.428，设置审计 #29）：图标取不到
                // 或为空图时，原 ?? UIImage() 是一张 0 尺寸空图，
                // 格子只剩名字；改显示与源格子同款灰底占位
                //（SourceIconView.placeholder：systemGray5 底 +
                // app.fill glyph），灰底铺满整个图标框。
                if let icon = czfResolvedIcon,
                   icon.size.width > 0, icon.size.height > 0 {
                    IconImageView(icon: icon)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        // 图标淡底影（3.8.422，建议第 2 条）：与源格子同款，
                        // 很淡的一层黑影（opacity 0.15），只把图标从亮背景
                        // 上托出来一点；不是 418 撤掉的那种卡片底。
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ZStack {
                        Color(uiColor: .systemGray5)
                        Image(systemName: "app.fill")
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.displayName)
                // 名字（3.8.421，建议第 3、4 条）：长名字自动缩小
                // （minimumScaleFactor 0.7），最多两行、超长仍截断
                // 加省略号（3.8.428，设置审计 #30：旧注释写“缩到
                // 两行内显示全、不再截断”，与 .lineLimit(2) 矛盾，
                // 只改注释、行数行为不动）；晕影按深浅模式换色
                //（3.8.428，设置审计 #37：源格子同款，深色黑晕影、
                // 浅色白晕影），黑字压在深色背景图上也能读。
                .font(.footnote)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                .shadow(color: colorScheme == .dark ? .black.opacity(0.95) : .white.opacity(0.95), radius: 4, x: 0, y: 0)
        }
        // 去阴影（3.8.418）：417 刚加的 AppBannerBG 卡片底撤掉——
        // 卡片在白底上看着像一层阴影，用户 19:09 报“源有阴影”。
        // App 格子回扁平（裸图标 + 名字），与源页格子一样，
        // 两页都无阴影。417 的去液体（切换行/批量底栏实底）保留。
        .contentShape(Rectangle())
        // VoiceOver：cell 不是 Button，启动/进设置全靠手势，
        // VoiceOver 不可用；合并为一个按钮元素，标签用 App 名，
        // 动作为启动（actions.onLaunch）。手势逻辑本身不动。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.displayName)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            actions.onLaunch(app)
        }
        // 单双击（3.8.419）：跟列表 banner 原来一样——单击启动、
        // 双击进设置。批量模式下改普通单击直接勾选，不要双击识别
        //（3.8.428，设置审计 #32 / App 页 #5：原来批量也走双击优先，
        // 单击要等约 0.3 秒双击超时才勾选）；手势分支见下
        // CZFAppGridTapGesture，VoiceOver 的 accessibilityAction
        // 调 onLaunch 不动（427 U8）。
        .modifier(CZFAppGridTapGesture(batchMode: batchMode, app: app, actions: actions))
        .overlay(alignment: .topTrailing) {
            if batchMode {
                Image(systemName: actions.isBatchSelected(app) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(actions.isBatchSelected(app) ? .accentColor : .secondary)
                    .background(Color(.systemBackground).opacity(0.85), in: Circle())
                    // 低 #55：勾选圈向外偏移，别压在图标一角。
                    .offset(x: 6, y: -6)
            }
        }
        .contextMenu {
            // 低 #9：批量模式下不挂 contextMenu——原来长按仍能调出
            // 删除/隐藏/锁定等破坏性菜单；空内容时不弹菜单。
            if !batchMode {
                czfContextMenu
            }
        }
        .alert("提示", isPresented: Binding(get: { czfCellError != nil }, set: { if !$0 { czfCellError = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) {
            }
        } message: {
            Text(czfCellError ?? "")
        }
        // O-13：图标首次生成放后台——快路径已有图标直接返回，
        // 未命中才后台生成，生成完回主线程刷 state；task 的 id
        // 是 App+明暗，cell 复用/滚动走后旧 task 即取消，
        // 取消了就不刷 state，不会刷到已复用的别的 cell。
        .task(id: czfCurrentIconKey) {
            if CZFAppIconLoader.cachedIconOnly(for: app.appInfo, darkModeIcon: darkModeIcon) != nil {
                return
            }
            let key = czfCurrentIconKey
            let icon = await CZFAppIconLoader.loadIcon(for: app.appInfo, darkModeIcon: darkModeIcon)
            guard !Task.isCancelled else { return }
            czfLoadedIcon = icon
            czfLoadedIconKey = key
        }
    }

    // 长按菜单：banner makeContextMenu() 的 SwiftUI 复刻（顶层项
    // 逐项接现有方法）。banner 里没有“置顶”这一项，网格也不编；
    // “保存图标”因要 UIDocumentPickerViewController 没复用。
    @ViewBuilder
    private var czfContextMenu: some View {
        // 1. Containers：多容器时才出现；三个一起改（选中、默认
        // 文件夹、dataUUID），与 banner 注释同款，免得重载丢选。
        if app.uiContainers.count > 1 {
            Menu("Containers") {
                ForEach(app.uiContainers, id: \.self) { container in
                    Button {
                        app.uiSelectedContainer = container
                        app.uiDefaultDataFolder = container.folderName
                        app.appInfo.dataUUID = container.folderName
                    } label: {
                        if container == app.uiSelectedContainer {
                            Label(container.name, systemImage: "checkmark")
                        } else {
                            Text(container.name)
                        }
                    }
                }
            }
        }
        // 2. 打开数据文件夹（banner openDataFolder 同款拼 URL）。
        if !app.uiIsShared, app.uiSelectedContainer != nil {
            Button("lc.appBanner.openDataFolder".loc, systemImage: "folder") {
                czfOpenDataFolder(for: app)
            }
        }
        // 多任务切换（banner 同款：标题按当前偏好翻）。
        if #available(iOS 16.0, *) {
            Button(
                app.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                systemImage: app.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus"
            ) {
                actions.onLaunchMultitask(app)
            }
        }
        // 添加到主屏幕：复制启动链接 + 创建 App Clip（保存图标未复用）。
        Menu("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app") {
            Button("lc.appBanner.copyLaunchUrl".loc, systemImage: "link") {
                czfCopyLaunchURL(for: app)
            }
            Button("lc.appBanner.createAppClip".loc, systemImage: "appclip") {
                Task { await actions.onCreateAppClip(app) }
            }
        }
        Button("lc.tabView.settings".loc, systemImage: "gear") {
            actions.onOpenSettings(app)
        }
        // 单 App VPN（banner 同款文案与开关语义）。
        Button(
            CZFVPNManager.isEnabled(for: app.appInfo) ? "关闭 VPN 打开" : "用 VPN 打开",
            systemImage: "globe"
        ) {
            actions.onToggleVPN(app)
        }
        // 插件文件夹多选（banner 同款：“无”清空，点一下勾/取消）。
        Menu("lc.appSettings.tweakFolder".loc, systemImage: "wrench.and.screwdriver") {
            Button("lc.common.none".loc) {
                app.uiTweakFolder = nil
            }
            ForEach(DataManager.shared.model.tweakFolderNames, id: \.self) { folderName in
                Button {
                    app.toggleTweakFolder(folderName)
                } label: {
                    if LCAppModel.czfSplitTweakFolders(app.uiTweakFolder).contains(folderName) {
                        Label(folderName, systemImage: "checkmark")
                    } else {
                        Text(folderName)
                    }
                }
            }
        }
        // 隐藏 / 恢复显示、锁定 / 解锁：banner 菜单里没有这两项，
        // 是网格多加的（调的都是 LCAppModel 已有方法，见报告）。
        Button(app.appInfo.isHidden ? "恢复显示" : "隐藏", systemImage: app.appInfo.isHidden ? "eye" : "eye.slash") {
            Task { await app.toggleHidden() }
        }
        Button(app.appInfo.isLocked ? "解锁" : "锁定", systemImage: app.appInfo.isLocked ? "lock.open" : "lock") {
            Task { await app.setLocked(newLockState: !app.appInfo.isLocked) }
        }
        if !app.uiIsShared {
            Button("lc.appBanner.uninstall".loc, systemImage: "trash", role: .destructive) {
                actions.onDeleteRequest(app)
            }
        }
    }

    // banner openDataFolder 同款：容器名先 percent-encoding 再拼
    // shareddocuments://，拼不出弹提示而不是静默 return。
    private func czfOpenDataFolder(for app: LCAppModel) {
        guard let folderName = app.uiSelectedContainer?.folderName,
              let encodedName = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(encodedName)") else {
            czfCellError = "无法打开数据文件夹"
            return
        }
        UIApplication.shared.open(url)
    }

    // banner copyLaunchUrl 同款。
    private func czfCopyLaunchURL(for app: LCAppModel) {
        guard let relativeBundlePath = app.appInfo.relativeBundlePath else { return }
        let encodedBundlePath = relativeBundlePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relativeBundlePath
        if let folderName = app.uiSelectedContainer?.folderName {
            let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folderName
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)&container-folder-name=\(encodedFolder)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(encodedBundlePath)"
        }
    }
}

// 网格设置 sheet：列数/图标大小改完立即生效（@AppStorage 双向
// 绑定）；底部“恢复原来模式”切回列表并 dismiss。
// MARK: - App 页自定义背景（3.8.413）
// 图片存 Documents/CZFAppBackground.jpg（等比缩到最长边 1600 再存，
// 原图几 MB 不直接落盘）；版本号放 @AppStorage，选图/清除时 +1，
// LCAppListView 监听版本号重读图片。部署目标 iOS 15 没有 PhotosPicker，
// 用 UIImagePickerController（iOS 15 可用）包一层。
enum CZFAppBackground {
    static let versionKey = "CZFAppBackgroundVersion"
    static let fileName = "CZFAppBackground.jpg"
    static var fileURL: URL { LCPath.docPath.appendingPathComponent(fileName) }
    static func loadImage() -> UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }
    static func save(_ image: UIImage) {
        let maxSide: CGFloat = 1600
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let data = (scaled ?? image).jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
    static var hasImage: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

// MARK: - 源页自定义背景（3.8.453）：与 App 页分开存。
// 用户要“源是源壁纸、App 是 App 壁纸”——之前两页共用同一张
// CZFAppBackground.jpg，源页设的图会盖掉 App 页的、反之亦然，
// 各以为是自己的。分开：源页存 CZFSourceBackground.jpg，
// 版本键 CZFSourceBackgroundVersion；App 页不动。
enum CZFSourceBackground {
    static let versionKey = "CZFSourceBackgroundVersion"
    static let fileName = "CZFSourceBackground.jpg"
    static var fileURL: URL { LCPath.docPath.appendingPathComponent(fileName) }
    static func loadImage() -> UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }
    static func save(_ image: UIImage) {
        let maxSide: CGFloat = 1600
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let scaled = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let data = (scaled ?? image).jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
    static var hasImage: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }
}

struct CZFAppBackgroundPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPick(image) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct CZFAppGridSettingsView: View {
    @Binding var columns: Int
    @Binding var iconSize: Int
    @Binding var gridMode: Bool
    // 排序入口只属于 App 页（3.8.431）：LCCustomSortView 排的是
    // 已安装 App。源页也共用这个设置页，之前没区分，源页点
    // “编辑排序”会打开 App 面板的排序页（用户 01:59 报
    // “编辑排序怎么编辑 APP 面板的了”）。源页传 false 藏掉。
    var showSort: Bool = true
    // 壁纸分家（3.8.453）：源页传 true，背景段读写
    // CZFSourceBackground；App 页默认 false，走 CZFAppBackground。
    var isSource: Bool = false
    @Environment(\.dismiss) private var dismiss
    // 自定义背景：版本号与列表页共用，选图/清除时 +1 触发列表页重读。
    // 两页各一把键，isSource 决定 bump 哪一把（见下面 helper）。
    @AppStorage(CZFAppBackground.versionKey) private var appBackgroundVersion = 0
    @AppStorage(CZFSourceBackground.versionKey) private var sourceBackgroundVersion = 0
    @State private var showBackgroundPicker = false
    @State private var backgroundThumb: UIImage?

    // 壁纸分家 helper（3.8.453）：背景段一律走这里，不直接碰
    // 某一页的存储，免得源页误写 App 的图。
    private func loadBackgroundThumb() -> UIImage? {
        isSource ? CZFSourceBackground.loadImage() : CZFAppBackground.loadImage()
    }
    private func saveBackground(_ image: UIImage) {
        if isSource { CZFSourceBackground.save(image) } else { CZFAppBackground.save(image) }
    }
    private func clearBackground() {
        if isSource { CZFSourceBackground.clear() } else { CZFAppBackground.clear() }
    }
    private var hasBackgroundImage: Bool {
        isSource ? CZFSourceBackground.hasImage : CZFAppBackground.hasImage
    }
    private func bumpBackgroundVersion() {
        if isSource { sourceBackgroundVersion += 1 } else { appBackgroundVersion += 1 }
    }
    // 自定义排序页（3.8.428，App 页 #6）：网格没有拖拽排序，
    // 从设置页进；与 LCAppListView 的排序菜单同款 sheet。
    @State private var showCustomSort = false

    var body: some View {
        NavigationView {
            Form {
                // 显示模式（3.8.419）：切换行收进设置（建议第 3 条）——
                // 列表/网格切换不再常驻占一行，改在这里切；改完
                // 立即生效（gridMode 是 Binding），点“完成”收起。
                Section("显示模式") {
                    Picker("显示模式", selection: $gridMode) {
                        Text("网格模式").tag(true)
                        Text("列表模式").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                // 排序入口（3.8.428，App 页 #6）：网格不能拖动排序
                //（LazyVGrid 拖拽重排风险大，这批只做设置入口），
                // 在设置页放显眼入口进自定义排序页；文案/图标照抄
                // App 页排序菜单里的“编辑排序”项
                //（LCAppListView.swift:606）。LCCustomSortView 保存时
                // 自己置排序类型为自定义，与菜单入口同款。
                // 3.8.431：源页不显示（showSort=false 时藏掉），
                // 否则源页点它会打开 App 面板的排序页。
                if showSort {
                    Section("排序") {
                        Button {
                            showCustomSort = true
                        } label: {
                            Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                        }
                    }
                }
                Section("列数") {
                    Picker("列数", selection: $columns) {
                        ForEach([3, 4, 5, 6], id: \.self) { count in
                            Text("\(count) 列").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("图标大小") {
                    Picker("图标大小", selection: $iconSize) {
                        Text("大").tag(0)
                        Text("中").tag(1)
                        Text("小").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section("背景") {
                    if let thumb = backgroundThumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button("选择背景图片") {
                        showBackgroundPicker = true
                    }
                    if hasBackgroundImage {
                        Button("清除背景", role: .destructive) {
                            clearBackground()
                            backgroundThumb = nil
                            bumpBackgroundVersion()
                        }
                    }
                }
                // “恢复原来模式”已并入上面的显示模式 Picker（选列表
                // 模式即恢复原来），不再单设一行。
            }
            .navigationTitle("网格设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                backgroundThumb = loadBackgroundThumb()
            }
            .sheet(isPresented: $showBackgroundPicker) {
                CZFAppBackgroundPicker { image in
                    saveBackground(image)
                    backgroundThumb = loadBackgroundThumb()
                    bumpBackgroundVersion()
                }
            }
            .sheet(isPresented: $showCustomSort) {
                LCCustomSortView()
            }
        }
    }
}
