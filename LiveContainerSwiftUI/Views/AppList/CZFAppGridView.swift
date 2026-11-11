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
    var actions: CZFAppGridActions
    var onRemoveApp: (LCAppModel) -> Void
    var onAuthenticateHidden: () -> Void
    var promptForGeneratedIconStyle: () async -> GeneratedIconStyle?
    var installMdm: (Data) -> Void

    @State private var czfGridDeleteTarget: LCAppModel?
    @State private var czfGridDeleteConfirm = false
    @State private var czfGridError: String?

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
            let failedContainers = try LCAppBannerViewController.deleteAppFiles(
                app,
                removeDataFolders: removeDataFolders,
                removeFromList: { model in onRemoveApp(model) }
            )
            if !failedContainers.isEmpty {
                czfGridError = "以下容器删除失败，已保留：\(failedContainers.joined(separator: "、"))"
            }
        } catch {
            czfGridError = error.localizedDescription
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: czfGridColumns, spacing: 16) {
            ForEach(apps, id: \.self) { app in
                CZFAppGridCell(
                    app: app,
                    iconFactor: czfIconFactor,
                    darkModeIcon: darkModeIcon,
                    batchMode: batchMode,
                    actions: czfCellActions()
                )
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
                }
            }
        }
        // 未解锁时保留原来的透明长按区（人脸识别唤起），不要删。
        if hiddenCount > 0 && !hiddenUnlocked {
            Color.clear
                .frame(height: LCAppBannerRootView.bannerHeight)
                .contentShape(Rectangle())
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

// 网格单元：大图标 + 下方单行名字。图标取法照抄 banner
//（LCAppBannerView.update：appInfo.iconIsDarkIcon(darkModeIcon)）。
// GeometryReader + aspectRatio(1) 让图标区成正方形，图标宽 =
// 单元宽 × 系数（最小 44），不依赖父视图量宽。
struct CZFAppGridCell: View {
    @ObservedObject var app: LCAppModel
    var iconFactor: CGFloat
    var darkModeIcon: Bool
    var batchMode: Bool
    var actions: CZFAppGridActions

    @State private var czfCellError: String?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let side = max(geo.size.width * iconFactor, 44)
                IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon) ?? UIImage())
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(app.displayName)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        // 板色（3.8.417）：格子加 AppBannerBG 浅蓝卡片底，与源页
        // 网格（3.8.416）同款——之前 App 格子没卡片、源页有卡片，
        // 两页界面不统一（用户 19:05 报）。圆角 16。
        .background(Color("AppBannerBG"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if batchMode {
                actions.onToggleBatchSelection(app)
            } else {
                actions.onLaunch(app)
            }
        }
        .overlay(alignment: .topTrailing) {
            if batchMode {
                Image(systemName: actions.isBatchSelected(app) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(actions.isBatchSelected(app) ? .accentColor : .secondary)
                    .background(Color(.systemBackground).opacity(0.85), in: Circle())
            }
        }
        .contextMenu {
            czfContextMenu
        }
        .alert("提示", isPresented: Binding(get: { czfCellError != nil }, set: { if !$0 { czfCellError = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) {
            }
        } message: {
            Text(czfCellError ?? "")
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
    @Environment(\.dismiss) private var dismiss
    // 自定义背景：版本号与列表页共用，选图/清除时 +1 触发列表页重读。
    @AppStorage(CZFAppBackground.versionKey) private var backgroundVersion = 0
    @State private var showBackgroundPicker = false
    @State private var backgroundThumb: UIImage?

    var body: some View {
        NavigationView {
            Form {
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
                    if CZFAppBackground.hasImage {
                        Button("清除背景", role: .destructive) {
                            CZFAppBackground.clear()
                            backgroundThumb = nil
                            backgroundVersion += 1
                        }
                    }
                }
                Section {
                    Button("恢复原来模式") {
                        gridMode = false
                        dismiss()
                    }
                }
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
                backgroundThumb = CZFAppBackground.loadImage()
            }
            .sheet(isPresented: $showBackgroundPicker) {
                CZFAppBackgroundPicker { image in
                    CZFAppBackground.save(image)
                    backgroundThumb = CZFAppBackground.loadImage()
                    backgroundVersion += 1
                }
            }
        }
    }
}
