//
//  LCTweaksView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LCTweakItem : Hashable {
    let fileUrl: URL
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool
    let isEnabled: Bool

    var displayName: String {
        let name = fileUrl.lastPathComponent
        return isEnabled ? name : String(name.dropLast(LCTweakItem.disabledSuffix.count))
    }

    static let disabledSuffix = ".disabled"
}

struct LCTweakFolderView : View {
    @State var baseUrl : URL
    @State var tweakItems : [LCTweakItem]
    private var isRoot : Bool
    @EnvironmentObject private var sharedModel: SharedModel
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    // 待确认删除：presentConfirmation 是 UIViewController 扩展，
    // 插件页是纯 SwiftUI View 挂不上，改用普通 alert（单删带名，
    // 左滑批量带数量），确认后才调 deleteTweakItem。
    @State private var pendingDeleteItem: LCTweakItem?
    @State private var showDeleteItemConfirm = false

    @StateObject private var newFolderInput = InputHelper()
    
    @StateObject private var renameFileInput = InputHelper()
    
    @State private var choosingTweak = false
    
    @State private var isTweakSigning = false

    // 导入插件进行中：点完导入没反馈就是缺这个（签名的转圈
    // 是现成的，导入照抄一套）
    @State private var isTweakInstalling = false

    // 导出分享表：长按菜单“导出”点开后要分享的文件
    @State private var exportItems: [URL] = []
    @State private var showExportSheet = false
    
    init(baseUrl: URL, isRoot: Bool = false) {
        _baseUrl = State(initialValue: baseUrl)
        self.isRoot = isRoot
        switch Self.scanTweakItems(at: baseUrl) {
        case .success(let items):
            _tweakItems = State(initialValue: items)
        case .failure(let error):
            _errorShow = State(initialValue: true)
            _errorInfo = State(initialValue: error.localizedDescription)
            _tweakItems = State(initialValue: [])
        }
    }

    // 3.8.571（L102）：目录扫描抽出来——init 只扫一次，源页/
    // 面板装插件是外部写盘（installTweak 写 Tweaks/<名>-<包名>
    // 文件夹），切走再切回时列表还停在旧数，新装的插件看不到，
    // 要重进模块才出现；onAppear 每现一次就重扫一遍。
    private static func scanTweakItems(at baseUrl: URL) -> Result<[LCTweakItem], Error> {
        let fm = FileManager()
        // 3.8.565（L294-1）：共享区目录只在分享流程里由 ensureAppGroupPaths 建——
        // 从没分享过的用户点“共享”分段时这里根本没目录，contentsOfDirectory
        // 直接抛 Cocoa 260、init 把 _errorShow 置真，弹一条系统原样错
        //（L288-1 同款，数据页“移回闲置文件夹”那路）；目录不存在就是
        // “还没有插件”，空表是正确语义。子文件夹视图只从已存在的行点进去，
        // 目录必存在，这道守卫只改缺目录的根分段。
        guard fm.fileExists(atPath: baseUrl.path) else { return .success([]) }
        do {
            let files = try fm.contentsOfDirectory(atPath: baseUrl.path)
            var items: [LCTweakItem] = []
            for fileName in files {
                let fileUrl = baseUrl.appendingPathComponent(fileName)
                var isFolder : ObjCBool = false
                fm.fileExists(atPath: fileUrl.path, isDirectory: &isFolder)
                let isEnabled = !fileName.hasSuffix(LCTweakItem.disabledSuffix)
                let baseName = isEnabled ? fileName : String(fileName.dropLast(LCTweakItem.disabledSuffix.count))
                let isFramework = isFolder.boolValue && baseName.hasSuffix(".framework")
                let isTweak = !isFolder.boolValue && baseName.hasSuffix(".dylib")
                // 插件列表只显示能注入的东西（文件夹/.framework/.dylib）：
                // 散文件（VPN 统计 .txt 等）只是插件写的数据，开关
                // 对它们没意义，还把列表撑得像一堆插件（用户点名）；
                // 文件本身留着，宿主设置页还在读统计，不删
                if !isFolder.boolValue && !isTweak {
                    continue
                }
                items.append(LCTweakItem(fileUrl: fileUrl, isFolder: isFolder.boolValue, isFramework: isFramework, isTweak: isTweak, isEnabled: isEnabled))
            }
            return .success(items)
        } catch {
            NSLog("[LC] failed to load tweaks \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func czfReloadTweakItems() {
        if case .success(let items) = Self.scanTweakItems(at: baseUrl) {
            tweakItems = items
        }
    }

    // 3.8.584（L116）：`.disabled` 是开关状态后缀、不是名字本身——
    // 用户在改名/新建框里敲了它，文件侧会造出双后缀（`Y.disabled.
    // disabled`）：扫描按去一次后缀的 baseName 认 .dylib，双后缀
    // 的 baseName 还带 `.disabled`、isTweak=false、不是文件夹，
    // 直接从列表消失、磁盘上还留着；启用的改成它则行显示启用、
    // 盘上是停用，开关撒谎。L96 只给注册表去了，文件侧漏了；
    // 输入与基名统一先去干净，下面的 enabled 分支该加才加。
    private static func czfCleanTweakName(_ name: String) -> String {
        var result = name
        while result.hasSuffix(LCTweakItem.disabledSuffix) {
            result = String(result.dropLast(LCTweakItem.disabledSuffix.count))
        }
        return result
    }

    var body: some View {
        List {
            // 无证书密码时工具栏签名按钮直接消失、用户不知道缺什么：
            // 这里留一行提示（按钮本身不动，只加提示一种），指到
            // 设置页导入证书。证书密码在设置页导入证书时一并设置。
            if LCSharedUtils.certificatePassword() == nil {
                Section {
                    Text("未设置证书密码，无法签名插件：去设置页导入证书并设置密码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if tweakItems.isEmpty {
                // 空态：照源页格式（图标 + 一句文案）；
                // 工具栏的导入/新建入口挂在 List 上，不受影响。
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "building.columns.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("暂无插件")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            Section {
                ForEach(tweakItems, id:\.self) { tweakItem in
                    HStack {
                        Group {
                            if tweakItem.isFolder && !tweakItem.isFramework {
                                // hidden link so the row navigates without the toggle triggering it
                                ZStack {
                                    NavigationLink {
                                        LCTweakFolderView(baseUrl: tweakItem.fileUrl, isRoot: false)
                                    } label: {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                    HStack {
                                        Label(tweakItem.displayName, systemImage: "folder.fill")
                                        Spacer()
                                        Image(systemName: "chevron.forward")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else if tweakItem.isFramework {
                                Label(tweakItem.displayName, systemImage: "shippingbox.fill")
                                Spacer()
                            } else if tweakItem.isTweak {
                                Label(tweakItem.displayName, systemImage: "building.columns.fill")
                                Spacer()
                            } else {
                                Label(tweakItem.displayName, systemImage: "document.fill")
                                Spacer()
                            }
                        }
                        .opacity(tweakItem.isEnabled ? 1 : 0.4)
                        if tweakItem.displayName != "TweakLoader.dylib" {
                            Toggle("", isOn: Binding(
                                get: { tweakItem.isEnabled },
                                set: { setTweakEnabled(tweakItem: tweakItem, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                    }
                    .contextMenu {
                        Button {
                            Task { await renameTweakItem(tweakItem: tweakItem)}
                        } label: {
                            Label("lc.common.rename".loc, systemImage: "pencil")
                        }

                        Button {
                            exportTweakItem(tweakItem: tweakItem)
                        } label: {
                            Label("lc.common.export".loc, systemImage: "square.and.arrow.up")
                        }

                        Button(role: .destructive) {
                            pendingDeleteItem = tweakItem
                            showDeleteItemConfirm = true
                        } label: {
                            Label("lc.common.delete".loc, systemImage: "trash")
                        }
                    }

                    // 3.8.317：左滑删除改走 swipeActions——原来的
                    // .onDelete 只弹确认框、不删数据，List 底层
                    // UICollectionView 已按“删了 1 条”算，数据源
                    // 仍是旧数，直接报 Invalid update（设置页 VPN
                    // 节点删在用节点同款真机实证）。swipeActions
                    // 的按钮不触发 List 自动删，点了才由代码删。
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteItem = tweakItem
                            showDeleteItemConfirm = true
                        } label: {
                            Label("lc.common.delete".loc, systemImage: "trash")
                        }
                    }
                }
            } footer: {
                if isRoot {
                    Text("lc.tweakView.globalFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                } else {
                    Text("lc.tweakView.appFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                }
            }
        }
        // 3.8.571（L102）：外部写盘后列表要跟上——源页/面板装
        // 插件直接写磁盘，不经过本视图的 tweakItems；切 Tab
        // 回来、从子文件夹返回时重扫一遍，新装的才出现。
        // 列表状态全由磁盘派生（开关/类型/名字都看文件名），
        // 重扫不会丢本视图自己的改动。
        .onAppear {
            czfReloadTweakItems()
        }
        .navigationTitle(isRoot ? "lc.tabView.tweaks".loc : baseUrl.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning && !isTweakInstalling && LCSharedUtils.certificatePassword() != nil {
                    Button {
                        Task { await signAllTweaks() }
                    } label: {
                        Label("sign".loc, systemImage: "signature")
                    }
                }

            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isTweakSigning && !isTweakInstalling {
                    Menu {
                        Button {
                            if choosingTweak {
                                choosingTweak = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                                    choosingTweak = true
                                })
                            } else {
                                choosingTweak = true
                            }
                        } label: {
                            Label("lc.tweakView.importTweak".loc, systemImage: "square.and.arrow.down")
                        }
                        
                        Button {
                            Task { await createNewFolder() }
                        } label: {
                            Label("lc.tweakView.newFolder".loc, systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Label("add", systemImage: "plus")
                    }
                } else {
                    ProgressView().progressViewStyle(.circular)
                }

            }
        }
        // 3.8.588（L120）：同一视图挂两个 .alert 只有最后一个生效——
        // SwiftUI 同一分支只认最外层一个弹窗（sarunw 实证：多 .alert
        // 同视图/同分支时只剩最后一个能弹）。原来错误弹窗被下面的
        // 删除确认盖掉，插件安装/签名/删除/导出失败全程静默。两个
        // 弹窗各挪一个 background 叶子、各占一条分支，宿主 List 上
        // 不再留 .alert；触发点与按钮一字不动。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: $errorShow) {
                    Button("lc.common.ok".loc, action: {
                    })
                } message: {
                    Text(errorInfo)
                }
        )
        // 单删确认：沙盒删除不进废纸篓，插件很可能只有这一份。
        // 3.8.588（L120）：同款——删除确认也挪叶子，与错误弹窗各占一条分支。
        .background(
            EmptyView()
                .alert("删除插件？", isPresented: $showDeleteItemConfirm) {
                    Button("lc.common.delete".loc, role: .destructive) {
                        if let item = pendingDeleteItem { deleteTweakItem(tweakItem: item) }
                        pendingDeleteItem = nil
                    }
                    Button("lc.common.cancel".loc, role: .cancel) { pendingDeleteItem = nil }
                } message: {
                    Text("删除后无法恢复")
                }
        )
        .sheet(isPresented: $showExportSheet) {
            if !exportItems.isEmpty {
                ActivityViewController(activityItems: exportItems)
            }
        }
        .textFieldAlert(
            isPresented: $newFolderInput.show,
            title: "lc.common.enterNewFolderName".loc,
            text: $newFolderInput.initVal,
            placeholder: "",
            action: { newText in
                newFolderInput.close(result: newText)
            },
            actionCancel: {_ in
                newFolderInput.close(result: "")
            }
        )
        .textFieldAlert(
            isPresented: $renameFileInput.show,
            title: "lc.common.enterNewName".loc,
            text: $renameFileInput.initVal,
            placeholder: "",
            action: { newText in
                renameFileInput.close(result: newText)
            },
            actionCancel: {_ in
                renameFileInput.close(result: "")
            }
        )
        .betterFileImporter(isPresented: $choosingTweak, types: [.dylib, .lcFramework, /*.deb*/], multiple: true, callback: { fileUrls in
            Task { await startInstallTweak(fileUrls) }
        }, onDismiss: {
            choosingTweak = false
        })
    }
    
    func setTweakEnabled(tweakItem: LCTweakItem, enabled: Bool) {
        if tweakItem.isEnabled == enabled {
            return
        }
        // 3.8.584（L116）：基名先去干净（见 czfCleanTweakName）——
        // 旧版改名框留下的行盘错位（行显示启用、盘上已停用），
        // displayName 只去一次后缀、enable 算出的目标名就是原
        // 文件名本身；目标名与原文件相同时不挪文件、只把行的开
        // 关状态纠回与盘上一致，挪到自身会抛错、行永远纠不过来。
        let baseName = Self.czfCleanTweakName(tweakItem.displayName)
        let newName = enabled ? baseName : baseName + LCTweakItem.disabledSuffix
        let newUrl = baseUrl.appendingPathComponent(newName)
        let fm = FileManager()
        if newUrl != tweakItem.fileUrl {
            do {
                try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
            } catch {
                errorShow = true
                errorInfo = error.localizedDescription
                return
            }
        }
        guard let index = tweakItems.firstIndex(of: tweakItem) else {
            return
        }
        tweakItems[index] = LCTweakItem(fileUrl: newUrl, isFolder: tweakItem.isFolder, isFramework: tweakItem.isFramework, isTweak: tweakItem.isTweak, isEnabled: enabled)
    }

    func deleteTweakItem(indexSet: IndexSet) {
        var indexToRemove : [Int] = []
        let fm = FileManager()
        do {
            for i in indexSet {
                let tweakItem = tweakItems[i]
                try fm.removeItem(at: tweakItem.fileUrl)
                indexToRemove.append(i)
            }
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            // 删了一半才报错也别直接 return：已删掉的项要从列表里
            // 去掉，不然列表里留着磁盘上已不存在的僵尸条目，点它
            // 还会再报错；没删成的那几项留在列表里不动。
        }
        if isRoot {
            for iToRemove in indexToRemove {
                sharedModel.tweakFolderNames.removeAll(where: { s in
                    return s == tweakItems[iToRemove].displayName
                })
            }
        }

        tweakItems.remove(atOffsets: IndexSet(indexToRemove))
    }

    func deleteTweakItem(tweakItem: LCTweakItem) {
        var indexToRemove : Int?
        let fm = FileManager()
        do {

            try fm.removeItem(at: tweakItem.fileUrl)
            indexToRemove = tweakItems.firstIndex(where: { s in
                return s == tweakItem
            })
        } catch {
            // 3.8.583（L114）：磁盘上已没了（外部删/同步清掉）——
            // 要删的终态本来就是“盘上无、表里无”，别报错、直接把
            // 行与注册表清掉，不然这行永远删不掉、每点一次报一次
            // 错（indexSet 版同款口径：不留僵尸条目）；盘上还在
            // 才是真删失败，照旧报错。
            if !fm.fileExists(atPath: tweakItem.fileUrl.path) {
                if let index = tweakItems.firstIndex(of: tweakItem) {
                    tweakItems.remove(at: index)
                }
                if isRoot {
                    sharedModel.tweakFolderNames.removeAll(where: { $0 == tweakItem.displayName })
                }
                return
            }
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }

        guard let indexToRemove = indexToRemove else {
            return
        }
        tweakItems.remove(at: indexToRemove)
        if isRoot {
            sharedModel.tweakFolderNames.removeAll(where: { s in
                return s == tweakItem.displayName
            })
        }
    }

    // 导出：长按菜单的备份口。dylib 行直接给文件；文件夹行递归收里面的
    // .dylib（加载器同样递归、同样跳过 .disabled）；.framework 行给整个包。
    // 已停用的 .dylib 文件名带 .disabled 后缀，分享表存出去要恢复成 .dylib
    // 才能再导入，所以先拷一份去临时目录再分享（临时目录系统会清）。
    func exportTweakItem(tweakItem: LCTweakItem) {
        let fm = FileManager()
        var urls: [URL] = []
        if tweakItem.isTweak {
            if tweakItem.isEnabled {
                urls = [tweakItem.fileUrl]
            } else {
                do {
                    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    let cleanUrl = tmpDir.appendingPathComponent(tweakItem.displayName)
                    try fm.copyItem(at: tweakItem.fileUrl, to: cleanUrl)
                    urls = [cleanUrl]
                } catch {
                    errorShow = true
                    errorInfo = error.localizedDescription
                    return
                }
            }
        } else if tweakItem.isFramework {
            // 3.8.569（L100）：已停用的 .framework 不能直接分享带
            // .disabled 后缀的目录——接收方用插件导入器导不回去
            //（导入器只认 .framework 后缀的包，.disabled 结尾的
            // 目录不在候选里）；与已停用 dylib 分享前先拷临时目录
            // 去后缀同款。启用的直接给原包，不动。
            if tweakItem.isEnabled {
                urls = [tweakItem.fileUrl]
            } else {
                do {
                    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    let cleanUrl = tmpDir.appendingPathComponent(tweakItem.displayName)
                    try fm.copyItem(at: tweakItem.fileUrl, to: cleanUrl)
                    urls = [cleanUrl]
                } catch {
                    errorShow = true
                    errorInfo = error.localizedDescription
                    return
                }
            }
        } else if tweakItem.isFolder {
            guard let enumerator = fm.enumerator(at: tweakItem.fileUrl, includingPropertiesForKeys: nil) else {
                errorShow = true
                errorInfo = "lc.tweakView.noDylibToExport".loc
                return
            }
            // 停用的 .dylib 也导出：单条导出会拷一份去临时目录、
            // 去掉 .disabled 后缀再分享；文件夹导出原来直接跳过，
            // 备份会丢已停用的插件，恢复后用户得重下。
            var tmpDir: URL?
            // 3.8.534（L61-5）：不同子文件夹里同名的已停用 dylib 去
            // .disabled 后缀后同名，拷进同一临时目录会撞名抛错、
            // 整个文件夹导出直接 abort（已收集的也一并丢掉）；重名
            // 加 -2/-3 去重。单条导出与已启用 dylib 不走临时目录，
            // 不受影响。
            // 3.8.567（L98）：先收全表、去重池先装已启用的 dylib
            // 名——原来只记已停用的干净名，`subA/X.dylib`（启用）+
            // `subB/X.dylib.disabled`（停用）同夹导出时会出两个
            // 都叫 `X.dylib` 的分享项；启用名先进池，停用的同名
            // 干净名就走 -2/-3。启用项本身直接给原文件，不动。
            let entries = enumerator.compactMap { $0 as? URL }
            var usedCleanNames = Set(entries.filter { $0.lastPathComponent.hasSuffix(".dylib") }.map { $0.lastPathComponent })
            // 3.8.568（L99）：已启用同名也记一本账——`subA/X.dylib` +
            // `subB/X.dylib` 两个都启用时上面只给原文件，分享表里
            // 出两个都叫 `X.dylib` 的项（L98 只修了启用-停用撞名）；
            // 第一个照旧给原文件，重复出现的才拷临时目录改 -2 名。
            var seenEnabledNames = Set<String>()
            // 3.8.575（L106）：夹里还有 .framework——加载器递归进子
            // 文件夹、.framework 当单个插件加载（TweakLoader.m
            // loadTweaksRecursively），但导出循环只收 .dylib/
            // .dylib.disabled；夹里的 framework 导出时丢了，恢复
            // 后插件就没了。池子与 dylib 分开记（后缀命名空间
            // 不同），去重口径与 dylib 同款：启用的名先进池。
            var usedFrameworkNames = Set(entries.filter { $0.lastPathComponent.hasSuffix(".framework") }.map { $0.lastPathComponent })
            var seenEnabledFrameworkNames = Set<String>()
            for entryURL in entries {
                let last = entryURL.lastPathComponent
                if last.hasSuffix(".dylib") {
                    if seenEnabledNames.contains(last) {
                        do {
                            if tmpDir == nil {
                                tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                try fm.createDirectory(at: tmpDir!, withIntermediateDirectories: true)
                            }
                            var cleanName = last
                            if usedCleanNames.contains(cleanName) {
                                let base = String(cleanName.dropLast(".dylib".count))
                                var n = 2
                                var cand = cleanName
                                while usedCleanNames.contains(cand) {
                                    cand = "\(base)-\(n).dylib"
                                    n += 1
                                }
                                cleanName = cand
                            }
                            usedCleanNames.insert(cleanName)
                            let cleanUrl = tmpDir!.appendingPathComponent(cleanName)
                            try fm.copyItem(at: entryURL, to: cleanUrl)
                            urls.append(cleanUrl)
                        } catch {
                            errorShow = true
                            errorInfo = error.localizedDescription
                            return
                        }
                    } else {
                        seenEnabledNames.insert(last)
                        urls.append(entryURL)
                    }
                } else if last.hasSuffix(".dylib" + LCTweakItem.disabledSuffix) {
                    do {
                        if tmpDir == nil {
                            tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try fm.createDirectory(at: tmpDir!, withIntermediateDirectories: true)
                        }
                        var cleanName = String(last.dropLast(LCTweakItem.disabledSuffix.count))
                        if usedCleanNames.contains(cleanName) {
                            let base = String(cleanName.dropLast(".dylib".count))
                            var n = 2
                            var cand = cleanName
                            while usedCleanNames.contains(cand) {
                                cand = "\(base)-\(n).dylib"
                                n += 1
                            }
                            cleanName = cand
                        }
                        usedCleanNames.insert(cleanName)
                        let cleanUrl = tmpDir!.appendingPathComponent(cleanName)
                        try fm.copyItem(at: entryURL, to: cleanUrl)
                        urls.append(cleanUrl)
                    } catch {
                        errorShow = true
                        errorInfo = error.localizedDescription
                        return
                    }
                } else if last.hasSuffix(".framework") {
                    // 3.8.575（L106）：启用的 .framework——第一个给原包，
                    // 重复的拷临时目录改 -2/-3 名（与 dylib 同款去重；
                    // 改名不影响加载，加载器按 Info.plist 找主二进制）。
                    if seenEnabledFrameworkNames.contains(last) {
                        do {
                            if tmpDir == nil {
                                tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                try fm.createDirectory(at: tmpDir!, withIntermediateDirectories: true)
                            }
                            var cleanName = last
                            if usedFrameworkNames.contains(cleanName) {
                                let base = String(cleanName.dropLast(".framework".count))
                                var n = 2
                                var cand = cleanName
                                while usedFrameworkNames.contains(cand) {
                                    cand = "\(base)-\(n).framework"
                                    n += 1
                                }
                                cleanName = cand
                            }
                            usedFrameworkNames.insert(cleanName)
                            let cleanUrl = tmpDir!.appendingPathComponent(cleanName)
                            try fm.copyItem(at: entryURL, to: cleanUrl)
                            urls.append(cleanUrl)
                        } catch {
                            errorShow = true
                            errorInfo = error.localizedDescription
                            return
                        }
                    } else {
                        seenEnabledFrameworkNames.insert(last)
                        urls.append(entryURL)
                    }
                } else if last.hasSuffix(".framework" + LCTweakItem.disabledSuffix) {
                    // 3.8.575（L106）：停用的 .framework——与单条导出
                    // 的 L100 同款，拷临时目录去 .disabled 后缀再分
                    // 享，同名走 -2/-3。
                    do {
                        if tmpDir == nil {
                            tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try fm.createDirectory(at: tmpDir!, withIntermediateDirectories: true)
                        }
                        var cleanName = String(last.dropLast(LCTweakItem.disabledSuffix.count))
                        if usedFrameworkNames.contains(cleanName) {
                            let base = String(cleanName.dropLast(".framework".count))
                            var n = 2
                            var cand = cleanName
                            while usedFrameworkNames.contains(cand) {
                                cand = "\(base)-\(n).framework"
                                n += 1
                            }
                            cleanName = cand
                        }
                        usedFrameworkNames.insert(cleanName)
                        let cleanUrl = tmpDir!.appendingPathComponent(cleanName)
                        try fm.copyItem(at: entryURL, to: cleanUrl)
                        urls.append(cleanUrl)
                    } catch {
                        errorShow = true
                        errorInfo = error.localizedDescription
                        return
                    }
                }
            }
            if urls.isEmpty {
                errorShow = true
                errorInfo = "lc.tweakView.noDylibToExport".loc
                return
            }
        } else {
            return
        }
        exportItems = urls
        showExportSheet = true
    }
    
    func renameTweakItem(tweakItem: LCTweakItem) async {
        guard let newName = await renameFileInput.open(initVal: tweakItem.displayName), newName != "" else {
            return
        }
        // 3.8.584（L116）：输入先去 `.disabled` 后缀（见
        // czfCleanTweakName），只剩后缀时当取消；不然改名会造出
        // 双后缀文件、从列表消失。
        let cleanName = Self.czfCleanTweakName(newName)
        guard cleanName != "" else {
            return
        }

        // 3.8.534（L61-2）：本函数从长按菜单按钮的裸 Task 调来、不在
        // 主 actor 上（L40 同款），tweakItems/sharedModel.
        // tweakFolderNames/errorInfo/errorShow 回主线程再读写；
        // 文件改名本身仍在外面做。
        let indexToRename = await MainActor.run {
            tweakItems.firstIndex(where: { s in
                return s == tweakItem
            })
        }
        guard let indexToRename = indexToRename else {
            return
        }
        let newFileName = tweakItem.isEnabled ? cleanName : cleanName + LCTweakItem.disabledSuffix
        let newUrl = self.baseUrl.appendingPathComponent(newFileName)

        // 3.8.541（L154）：改成原名时不挪文件——moveItem 挪到自身会抛错、
        // 弹一条“已存在”报错；改名框默认填的就是原名，不改直接点确定
        // 是正常操作，不是错。setTweakEnabled（L116）同款守卫在位。
        guard newUrl != tweakItem.fileUrl else { return }

        let fm = FileManager()
        do {
            try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
        } catch {
            await MainActor.run {
                errorShow = true
                errorInfo = error.localizedDescription
            }
            return
        }
        await MainActor.run {
            // 3.8.595（L128）：下标不能用改名前取的——改名在裸 Task
            // 里落盘，落盘与回写之间 tweakItems 可能变（开关原位替
            // 换不移位、导入在尾部追加不移位，但删行会让后面的下标
            // 全前移一位、切页重扫会整表换序），旧下标指向的可能
            // 已是另一行，remove(at:) 会删错行；回写时按原 fileUrl
            // 再找一次，找不到说明行已不在（外部删了），只留盘上
            // 新名、下次 onAppear 重扫收进来，不动别的行。
            guard let idx = tweakItems.firstIndex(where: { $0.fileUrl == tweakItem.fileUrl }) else { return }
            tweakItems.remove(at: idx)
            let newTweakItem = LCTweakItem(fileUrl: newUrl, isFolder: tweakItem.isFolder, isFramework: tweakItem.isFramework, isTweak: tweakItem.isTweak, isEnabled: tweakItem.isEnabled)
            tweakItems.insert(newTweakItem, at: idx)

            if isRoot {
                // 3.8.565（L96）：注册表里只存去后缀的名（冷启动
                // 扫描同款口径）——原来直接插用户敲的新名，改成
                // `X.disabled` 会进一条带后缀的键，下次开 App 设
                // 置的菜单里 `X` 与 `X.disabled` 各一条；新名去
                // 后缀后若已在表里（磁盘上已有 `X.disabled`），
                // 不再插第二条，ForEach(id: \.self) 不撞重名。
                let registryName = cleanName.hasSuffix(LCTweakItem.disabledSuffix) ? String(cleanName.dropLast(LCTweakItem.disabledSuffix.count)) : cleanName
                // 3.8.564（L316-1）：旧名不在表里时别直接 return——
                // 本机/共享根目录下外部新建（文件 App、iCloud 同步）
                // 的夹，冷启动扫描只在启动时记一次，会话中途建的旧
                // 名根本不在 tweakFolderNames 里；改名后新名也跟着
                // 丢，App 设置/网格/横幅菜单要等下次冷启动才看得到
                // 改名后的夹（L302-1/L303-1/L306-1 同款注册表漏）。
                // 找得到就原位替换，找不到就按 L96 口径补一条；
                // .dylib 不是文件夹、不进注册表（冷启动扫描只记目录）。
                // 刚导入的 .framework 行里 isFolder 恒 false（导入
                // 追加处写死），须另认 isFramework。
                if let indexToRename2 = sharedModel.tweakFolderNames.firstIndex(of: tweakItem.displayName) {
                    sharedModel.tweakFolderNames.remove(at: indexToRename2)
                    if !sharedModel.tweakFolderNames.contains(registryName) {
                        sharedModel.tweakFolderNames.insert(registryName, at: indexToRename2)
                    }
                } else if (tweakItem.isFolder || tweakItem.isFramework) && !sharedModel.tweakFolderNames.contains(registryName) {
                    sharedModel.tweakFolderNames.append(registryName)
                }
            }
        }
    }
    
    func signAllTweaks() async {
        // 3.8.534（L61-2）：本函数从工具栏按钮的裸 Task 调来、不在
        // 主 actor 上（L40 同款：Swift 5 语言模式下 Button 的 @escaping
        // action 不继承 body 的 @MainActor）；isTweakSigning/errorInfo/
        // errorShow 是 @State，回主线程再写。进度回调更跑在签名串行
        // 队列起的后台 Task 里（LCUtilsExtensions signTweaksImpl
        // :298/:336 同步调 progressHandler），同步闭包里不能 await，
        // 用 Task { @MainActor in }（AGENTS.md 既定修法）。defer 里
        // 不能 await，改尾部两路同跳清（L44 batchHide 同款）。
        // L33 曾判“4 处 Task 在 View 内、主 actor 继承”——不成立，
        // 见上，进度回调那路与 Button 语义无关、必在后台线程。
        do {
            try await LCUtils.signTweaks(tweakFolderUrl: self.baseUrl, force: true) { p in
                Task { @MainActor in isTweakSigning = true }
            }
            await MainActor.run { isTweakSigning = false }
        } catch {
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
                isTweakSigning = false
            }
            return
        }
    }
    
    func createNewFolder() async {
        // 3.8.559（L90）：原来调的是 renameFileInput——新建文件夹弹的是改名框（标题“输入新名称”），newFolderInput 专用的新建框（标题“输入新文件夹名称”）从来没人打开；改调它。两 helper 的 open() 都是无参清 initVal 再弹，行为除标题外不变。
        guard let newName = await newFolderInput.open(), newName != "" else {
            return
        }
        // 3.8.584（L116）：输入先去 `.disabled` 后缀（见
        // czfCleanTweakName），只剩后缀时当取消；不然新建的夹名
        // 字带后缀、加载器直接按停用跳过，行却显示启用。
        let cleanName = Self.czfCleanTweakName(newName)
        guard cleanName != "" else {
            return
        }
        // 3.8.534（L61-2）：本函数从菜单按钮的裸 Task 调来、不在
        // 主 actor 上（L40 同款），tweakItems/sharedModel.
        // tweakFolderNames/errorInfo/errorShow 回主线程再写；
        // 建目录本身仍在外面做。
        let fm = FileManager()
        // 3.8.566（L298-1）：共享区目录只在分享流程里建——从没分享过的用户点“共享”分段进新建文件夹时 baseUrl 根本不存在，createDirectory（withIntermediateDirectories: false）直接抛 Cocoa 4、弹系统原样错（L294-1 同款，读路修了、写路漏了）；写路先把 baseUrl 建出来（只建 baseUrl 这一级链，dest 本身仍用 false、带“/”的名字照旧报错，建不出时下面照旧报）。
        try? fm.createDirectory(at: baseUrl, withIntermediateDirectories: true)
        let dest = baseUrl.appendingPathComponent(cleanName)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            await MainActor.run {
                errorShow = true
                errorInfo = error.localizedDescription
            }
            return
        }
        await MainActor.run {
            tweakItems.append(LCTweakItem(fileUrl: dest, isFolder: true, isFramework: false, isTweak: false, isEnabled: true))
            if isRoot {
                // 3.8.565（L96）：新建也只记去后缀的名、且表里
                // 没有才加——开关关掉 `X`（磁盘 `X.disabled`、
                // 表里还是 `X`）后又新建同名 `X`，原来直接 append
                // 就造出两个 `X`，App 设置/网格两处 ForEach(id:
                // \.self) 撞重名；名字本身带 `.disabled` 也一样
                // 去后缀再记，与冷启动扫描同口径。
                let registryName = cleanName.hasSuffix(LCTweakItem.disabledSuffix) ? String(cleanName.dropLast(LCTweakItem.disabledSuffix.count)) : cleanName
                if !sharedModel.tweakFolderNames.contains(registryName) {
                    sharedModel.tweakFolderNames.append(registryName)
                }
            }
        }
    }
    
    func startInstallTweak(_ urls: [URL]) async {
        // 3.8.534（L61-2）：本函数从文件导入回调的裸 Task 调来、不在
        // 主 actor 上（L40 同款；回调方是 DocModifier 的 Coordinator，
        // 普通 NSObject 方法）；isTweakInstalling/tweakItems/errorInfo/
        // errorShow 是 @State，回主线程再写。
        // 3.8.557（L236-1）：逐个 try——原来整个循环共用外层一个 try，
        // 导入器是多选（:350 multiple: true），中间一个文件重名
        // moveItem 抛错就进 catch、后面的文件一个都不装，还只报第
        // 一个错（L150/L152 同款共用 try 中断）；各记各的失败、装
        // 完再汇总报，前面装好的不受影响。
        await MainActor.run { isTweakInstalling = true }
        let fm = FileManager()
        // 3.8.566（L298-1）：同上——共享区没目录时 moveItem 到 baseUrl 下直接抛，整批导入全报失败；先把 baseUrl 建出来，建不出时逐项 moveItem 照旧报错，不静默吞掉。
        try? fm.createDirectory(at: self.baseUrl, withIntermediateDirectories: true)
        // we will sign later before app launch
        var failedNames: [String] = []
        var firstError: String? = nil
        for fileUrl in urls {
            do {
                // handle deb file
                if(!fileUrl.isFileURL) {
                    throw "lc.tweakView.notFileError %@".localizeWithFormat(fileUrl.lastPathComponent)
                }
                let toPath = self.baseUrl.appendingPathComponent(fileUrl.lastPathComponent)
                try fm.moveItem(at: fileUrl, to: toPath)

                let isFramework = toPath.lastPathComponent.hasSuffix(".framework")
                let isTweak = toPath.lastPathComponent.hasSuffix(".dylib")
                // 3.8.575（L106）：.framework 是目录，LCParseMachO
                // 在目录上 open(O_RDWR) 直接 EISDIR 失败、rpath
                // 补丁悄悄跳过，导进来的 framework 主二进制永远没
                // 打上与 dylib 同款的 rpath，链了同夹 dylib 的加
                // 载时 dlopen 找不到。按签名侧同款
                // （LCUtilsExtensions signTweakImpl）用 Bundle
                // 取主二进制再打；取不到就不打，导入本身照常成功。
                if isFramework {
                    if let executableURL = Bundle(url: toPath)?.executableURL {
                        LCParseMachO((executableURL.path as NSString).utf8String, false) { path, header, _, _ in
                            LCPatchAddRPath(path, header)
                        }
                    }
                } else {
                    LCParseMachO((toPath.path as NSString).utf8String, false) { path, header, _, _ in
                        LCPatchAddRPath(path, header);
                    }
                }
                // 3.8.571（L102）：导入中途切走再切回时 onAppear
                // 重扫已把刚移好的文件收进列表，追加前先判重，
                // 不然同一文件两行、ForEach(id: \.self) 撞重名。
                await MainActor.run {
                    if !self.tweakItems.contains(where: { $0.fileUrl == toPath }) {
                        self.tweakItems.append(LCTweakItem(fileUrl: toPath, isFolder: false, isFramework: isFramework, isTweak: isTweak, isEnabled: true))
                    }
                    if isRoot && isFramework {
                        // 3.8.557（L306-1）：模块页导入 .framework 只 moveItem、不进 tweakFolderNames 注册表——
                        // 注册表只在冷启动扫描与模块页新建/改名时维护；源页（S:1753）与面板（K:4936）
                        // 同款漏了，L303-1/L302-1 已修，模块页导入这里也漏了。本次启动内 App 设置
                        // （LCAppSettingsView.swift:399）/网格（CZFAppGridView.swift:728）/横幅菜单
                        // （LCAppBannerViewController.swift:477）看不到刚导入的 framework、挂不上去，
                        // 重启才出现。按 L96 口径（去 .disabled 后缀、表里没有才加）登记；子文件夹
                        // 不记、.dylib 不记；失败走 catch，不登记。
                        let folderName = toPath.lastPathComponent
                        let registryName = folderName.hasSuffix(LCTweakItem.disabledSuffix) ? String(folderName.dropLast(LCTweakItem.disabledSuffix.count)) : folderName
                        if !sharedModel.tweakFolderNames.contains(registryName) {
                            sharedModel.tweakFolderNames.append(registryName)
                        }
                    }
                }
            } catch {
                failedNames.append(fileUrl.lastPathComponent)
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        await MainActor.run {
            isTweakInstalling = false
            if !failedNames.isEmpty {
                var text = "已导入 \(urls.count - failedNames.count) 个插件，以下 \(failedNames.count) 个导入失败：\(failedNames.joined(separator: "、"))"
                if let firstError {
                    text += "（\(firstError)）"
                }
                errorInfo = text
                errorShow = true
            }
        }
    }
}

struct LCTweaksView: View {
    // 模块分三处：本机（Documents/Tweaks）、共享（App Group）、VPN。
    // 转共享后文件夹搬去了共享处，不切过去就永远看不到、也开不回来。
    // VPN 分段是原设置页 VPN 区整段搬过来（3.8.328），设置页不再留；
    // CZFVPN 那行开关不动（它只是模块开关，VPN 设置是另一回事）。
    private enum TweakTab: Hashable {
        case local, shared, vpn
    }
    @State private var selectedTab: TweakTab = .vpn
    // R-1（3.8.453 修 453 红字）：.onChange 要读 sharedModel，
    // 但 LCTweaksView 本来没有这把 @EnvironmentObject——
    // 有它的是子视图 LCTweakFolderView。补上，TabView 层已注入
    // SharedModel（LCTabView:16 同款），环境里有，不会崩。
    @EnvironmentObject private var sharedModel: SharedModel

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 3.8.413：标题放这层，三个分段都有——原来只在
                // LCTweakFolderView 里设，切到 VPN 分段时
                // CZFVPNSettingsView 没设标题，导航栏空了、
                // 分段顶到屏顶、Form 满屏敞开（用户 11-11 截图）。
                // 文件夹页自己的标题（子文件夹名）更深，会盖掉这层，
                // 根目录与 VPN 都显示“模块”。
                Picker("", selection: $selectedTab) {
                    Text("本机").tag(TweakTab.local)
                    Text("共享").tag(TweakTab.shared)
                    Text("VPN").tag(TweakTab.vpn)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                if selectedTab == .vpn {
                    CZFVPNSettingsView()
                } else {
                    LCTweakFolderView(baseUrl: selectedTab == .shared ? LCPath.lcGroupTweakPath : LCPath.tweakPath, isRoot: true)
                        .id(selectedTab)
                }
            }
            .navigationTitle("lc.tabView.tweaks".loc)
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // R-1：App 页盾牌菜单“前往 VPN 设置”切过来时，若当前
        // 在本机/共享分段，监听 SharedModel 的触发计数，切到
        // VPN 分段（默认已是 .vpn，见上面声明）。
        .onChange(of: sharedModel.czfTweakVPNRequest) { _ in
            selectedTab = .vpn
        }

    }
}
