//
//  LCMultiLCManagementView.swift
//  LiveContainer
//
//  Created by s s on 2025/9/1.
//

import SwiftUI

protocol InstallAnotherLCButtonDelegate {
    func installAnotherLC(name: String) async
}

private let multiLCLaunchPriorityKey = "LCMultiLaunchPriority"

private struct LaunchPriorityLC: Identifiable, Hashable {
    let scheme: String
    let displayName: String

    var id: String { scheme }
}

private let knownLiveContainers = [
    LaunchPriorityLC(scheme: "livecontainer", displayName: "LiveContainer"),
    LaunchPriorityLC(scheme: "livecontainer2", displayName: "LiveContainer2"),
    LaunchPriorityLC(scheme: "livecontainer3", displayName: "LiveContainer3")
]

struct InstallAnotherLCButton : View {
    @State var lcName : String
    @State var detected = false
    let delegate : InstallAnotherLCButtonDelegate
    
    init(lcName: String, delegate: InstallAnotherLCButtonDelegate) {
        self._lcName = State(initialValue: lcName)
        self._detected = State(initialValue: UIApplication.shared.canOpenURL(URL(string: "\(lcName.lowercased())://")!))
        self.delegate = delegate
    }
    
    var body: some View {
        Button {
            Task { await delegate.installAnotherLC(name: lcName)}
        } label: {
            HStack {
                LCSettingsIcon(systemName: "plus.app", color: .green)
                Text(lcName)
                Spacer()
                if detected {
                    Text("✓")
                        .foregroundStyle(.green)
                } else {
                    Text("✗")
                        .foregroundStyle(.gray)
                }

            }
        }
        .onForeground {
            updateInstallStatus()
        }
    }
    
    func updateInstallStatus() {
        detected = UIApplication.shared.canOpenURL(URL(string: "\(lcName.lowercased())://")!)
    }
}

struct LCMultiLCManagementView : View, InstallAnotherLCButtonDelegate {
    @AppStorage("LCMultiAllowGameCategory") var useGameCategory = false
    @AppStorage("LCMultiAllowGameMode") var allowGameMode = false
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""
    
    @State private var showShareSheet = false
    @State private var shareURL : URL? = nil
    @StateObject private var installLC2Alert = AlertHelper<Int>()
    @State private var launchPriorityItems: [LaunchPriorityLC] = []

    let storeName = LCUtils.getStoreName()

    var body: some View {
        Form {
            Section {
                InstallAnotherLCButton(lcName: "LiveContainer2", delegate: self)
                InstallAnotherLCButton(lcName: "LiveContainer3", delegate: self)
            } header: {
                Text("lc.settings.multiLCInstall".loc)
            }

            Section {
                ForEach(launchPriorityItems) { item in
                    Text(item.displayName)
                }
                .onMove { source, destination in
                    launchPriorityItems.move(fromOffsets: source, toOffset: destination)
                    saveLaunchPriority()
                }
            } header: {
                Text("lc.settings.multiLCLaunchPriority".loc)
            } footer: {
                Text("lc.settings.multiLCLaunchPriorityDesc".loc)
            }
            Section {
                Toggle(isOn: $useGameCategory) {
                    HStack {
                        LCSettingsIcon(systemName: "gamecontroller.fill", color: .purple)
                        Text("lc.settings.multiLCInstall.useGameCategory".loc)
                    }
                }
                Toggle(isOn: $allowGameMode) {
                    HStack {
                        LCSettingsIcon(systemName: "gamecontroller", color: .green)
                        Text("lc.settings.multiLCInstall.allowGameMode".loc)
                    }
                }
            } header: {
                Text("lc.common.miscellaneous".loc)
            }
        }
        .environment(\.editMode, .constant(.active))
        .onAppear {
            reloadLaunchPriorityItems()
        }
        // 3.8.589（L121）：同一视图挂多个 .alert/.confirmationDialog 只有最后一个生效——
        // SwiftUI 同一分支只认最外层一个弹窗（sarunw 实证，L120 同款）。
        // 各挪一个 background 叶子、各占一条分支，宿主链上不再留弹窗类修饰符；触发点与按钮一字不动。
        .background(
            EmptyView()
                .alert("lc.settings.multiLCInstall".loc, isPresented: $installLC2Alert.show) {
                    if(UserDefaults.sideStoreExist()) {
                        Button {
                            installLC2Alert.close(result: 2)
                        } label: {
                            Text("lc.settings.multiLCInstall.installWithBuiltInSideStore".loc)
                        }
                    }
            
                    Button {
                        installLC2Alert.close(result: 1)
                    } label: {
                        Text("lc.common.continue".loc)
                    }
            
                    Button("lc.common.cancel".loc, role: .cancel) {
                        installLC2Alert.close(result: 0)
                    }
                } message: {
                    Text("lc.settings.multiLCInstallAlertDesc %@".localizeWithFormat(storeName))
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: $errorShow) {
                } message: {
                    Text(errorInfo)
                }
        )
        .sheet(isPresented: $showShareSheet) {
            if let shareURL = shareURL {
                ActivityViewController(activityItems: [shareURL])
            }
        }
        .navigationTitle("lc.settings.multiLC".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func isInstalled(scheme: String) -> Bool {
        if scheme == "livecontainer" {
            return true
        }
        guard let url = URL(string: "\(scheme)://") else {
            return false
        }
        return UIApplication.shared.canOpenURL(url)
    }

    private func reloadLaunchPriorityItems() {
        let installedItems = knownLiveContainers.filter { isInstalled(scheme: $0.scheme) }
        let installedByScheme = Dictionary(uniqueKeysWithValues: installedItems.map { ($0.scheme, $0) })
        let installedSchemes = Set(installedItems.map(\.scheme))
        let savedSchemes = LCUtils.appGroupUserDefault.array(forKey: multiLCLaunchPriorityKey) as? [String] ?? []
        var orderedSchemes: [String] = []

        for rawScheme in savedSchemes {
            let scheme = rawScheme.lowercased()
            guard installedSchemes.contains(scheme), !orderedSchemes.contains(scheme) else {
                continue
            }
            orderedSchemes.append(scheme)
        }

        for item in installedItems {
            if !orderedSchemes.contains(item.scheme) {
                orderedSchemes.append(item.scheme)
            }
        }

        launchPriorityItems = orderedSchemes.compactMap { installedByScheme[$0] }
        saveLaunchPriority()
    }

    private func saveLaunchPriority() {
        LCUtils.appGroupUserDefault.set(launchPriorityItems.map(\.scheme), forKey: multiLCLaunchPriorityKey)
    }

    func installAnotherLC(name: String) async {
        if !LCUtils.isAppGroupAltStoreLike() {
            // 3.8.579（L409-1）：本函数从按钮的裸 Task 调来（:42，Swift 5.0 靶下 Button 闭包的 Task 不继承 MainActor），不在主 actor 上；errorInfo/errorShow 是 @State（:71-72，.alert :156 读它），离主线程写报 Publishing changes、不支持安装法的报错弹框可能不出（L40/L44/L399-1 同款——本文件之前只有 openSideStore 的 onError 一路包过，其余四处全漏了）。@AppStorage 读（:225/:228）是 UserDefaults 读、线程安全，不动；打包/书签/UserDefaults 写留在外面。
            await MainActor.run {
                errorInfo = "lc.settings.unsupportedInstallMethod".loc
                errorShow = true
            }
            return;
        }
        
        guard let result = await installLC2Alert.open(), result != 0 else {
            return
        }
        
        do {
            var extraInfo: [String : Any] = [:]
            if useGameCategory {
                extraInfo["LSApplicationCategoryType"] = "public.app-category.games"
            }
            if allowGameMode {
                extraInfo["GCSupportsGameMode"] = true
                extraInfo["LSSupportsGameMode"] = true
            }
            let packedIpaUrl = try LCUtils.archiveIPA(withBundleName: name, includingExtraInfoDict: extraInfo)
            
            // 3.8.579（L409-1）：同上，shareURL 是 @State（:77，.sheet :161-163 读它），回主线程再写。
            await MainActor.run {
                shareURL = packedIpaUrl
            }
            
            if(result == 2) {
                let launchURLStr = packedIpaUrl.absoluteString
                let bookmark = try packedIpaUrl.bookmarkData(
                    options: URL.BookmarkCreationOptions(rawValue: 1 << 11),
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionFileBookmark")
                // 启动失败要报出来，别静默吞掉（见 openSideStore 的 onError）。
                LCUtils.openSideStore(urlStr: launchURLStr) { error in
                    Task {
                        await MainActor.run {
                            errorInfo = error.localizedDescription
                            errorShow = true
                        }
                    }
                }
                return
            }
            
            // 3.8.579（L409-1）：同上，showShareSheet 是 @State（:76，.sheet :161 读它），回主线程再写。
            await MainActor.run {
                showShareSheet = true
            }
            
        } catch {
            // 3.8.579（L409-1）：同上，catch 里的 @State 写回主线程。
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
    }
}
