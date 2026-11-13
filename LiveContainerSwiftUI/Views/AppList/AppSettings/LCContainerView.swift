//
//  LCContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import SwiftUI

protocol LCContainerViewDelegate {
    func unbindContainer(container: LCContainer)
    func setDefaultContainer(container: LCContainer)
    func saveContainer(container: LCContainer)
    
    func getSettingsBundle() -> Bundle?
    func getContainerURL(container: LCContainer) -> URL
    func getBundleId() -> String
}

struct LCContainerView : View {
    @ObservedObject var container : LCContainer
    let delegate : LCContainerViewDelegate
    @Binding var uiDefaultDataFolder : String?
    @State var settingsBundle : Bundle? = nil
    
    @StateObject private var removeContainerAlert = YesNoHelper()
    @StateObject private var deleteDataAlert = YesNoHelper()
    @StateObject private var removeKeychainAlert = YesNoHelper()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel : SharedModel
    @State private var typingContainerName : String = ""
    @State private var typingIDFV: String = ""
    @State private var inUse = false
    @State private var runningLC : String? = nil
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""
    
    init(container: LCContainer, uiDefaultDataFolder : Binding<String?>, delegate: LCContainerViewDelegate) {
        self._container = ObservedObject(initialValue: container)
        self.delegate = delegate
        self._typingContainerName = State(initialValue: container.name)
        self._uiDefaultDataFolder = Binding(projectedValue: uiDefaultDataFolder)
    }
    
    var body: some View {
        Form {
            if !(container.storageBookMark != nil && container.resolvedContainerURL == nil) {
                
                Section {
                    HStack {
                        Text("lc.container.containerName".loc)
                        Spacer()
                        TextField("lc.container.containerName".loc, text: $typingContainerName)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                container.name = typingContainerName
                                saveContainer()
                            }
                    }
                    HStack {
                        Text("lc.container.containerFolderName".loc)
                        Spacer()
                        Text(container.folderName)
                            .foregroundStyle(.gray)
                    }
                    Toggle(isOn: $container.isolateAppGroup) {
                        Text("lc.container.isolateAppGroup".loc)
                    }
                    .onChange(of: container.isolateAppGroup) { newValue in
                        saveContainer()
                    }
                    
                    if let settingsBundle {
                        NavigationLink {
                            AppPreferenceView(bundleId: delegate.getBundleId(), settingsBundle: settingsBundle, containerURL: delegate.getContainerURL(container: container))
                        } label: {
                            Text("lc.container.preferences".loc)
                        }
                    }
                    if container.folderName == uiDefaultDataFolder {
                        Text("lc.container.alreadyDefaultContainer".loc)
                            .foregroundStyle(.gray)
                    } else {
                        Button {
                            setAsDefault()
                        } label: {
                            Text("lc.container.setDefaultContainer".loc)
                        }
                    }
                } footer: {
                    Text("lc.container.defaultContainerDesc".loc)
                }
                
                Section {
                    Toggle(isOn: $container.spoofIdentifierForVendor) {
                        Text("lc.container.spoofIdentifierForVendor".loc)
                    }
                    .onChange(of: container.spoofIdentifierForVendor) { newValue in
                        saveContainer()
                    }
                    
                    if container.spoofIdentifierForVendor {
                        HStack {
                            Text("UUID")
                            TextField("lc.common.auto".loc, text: $typingIDFV)
                                .multilineTextAlignment(.trailing)
                                .onSubmit {
                                    saveIDFV()
                                }
                        }
                    }
                }

                Section {
                    Toggle(isOn: $container.spoofDeviceFingerprint) {
                        Text("lc.container.spoofDeviceFingerprint".loc)
                    }
                    .onChange(of: container.spoofDeviceFingerprint) { newValue in
                        saveContainer()
                    }

                    // 指纹值只读展示：打开时自动生成、固定不变，
                    // 让用户一眼看出每个分身是哪套环境。
                    if container.spoofDeviceFingerprint {
                        HStack {
                            Text("IDFA")
                            Spacer()
                            Text(container.spoofedAdvertisingIdentifier ?? "")
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack {
                            Text("lc.container.spoofedDeviceName".loc)
                            Spacer()
                            Text(container.spoofedDeviceName ?? "")
                                .foregroundStyle(.gray)
                        }
                        HStack {
                            Text("lc.container.spoofedSystemVersion".loc)
                            Spacer()
                            Text(container.spoofedSystemVersion ?? "")
                                .foregroundStyle(.gray)
                        }
                        HStack {
                            Text("lc.container.spoofedMachine".loc)
                            Spacer()
                            Text(container.spoofedMachine ?? "")
                                .foregroundStyle(.gray)
                        }
                    }
                }

                Section {
                    if inUse {
                        Text("lc.container.inUse".loc)
                            .foregroundStyle(.gray)
                        
                    } else {
                        if !container.isShared || container.storageBookMark != nil {
                            Button {
                                openDataFolder()
                            } label: {
                                Text("lc.appBanner.openDataFolder".loc)
                            }
                            Button {
                                unbindContainer()
                            } label: {
                                Text("lc.container.unbind".loc)
                            }
                        }
                        Button(role:.destructive) {
                            Task { await deleteData() }
                        } label: {
                            Text("lc.container.deleteData".loc)
                        }
                        
                        Button(role:.destructive) {
                            Task { await cleanUpKeychain() }
                        } label: {
                            Text("lc.settings.cleanKeychain".loc)
                        }
                        
                        if(container.storageBookMark == nil) {
                            Button(role:.destructive) {
                                Task { await removeContainer() }
                            } label: {
                                Text("lc.container.removeContainer".loc)
                            }
                        }
                        
                    }
                }
            } else {
                Section {
                    if container.bookmarkResolved {
                        Text("lc.container.externalStorageUnavailable".loc)
                    } else {
                        Text("lc.container.bookmarkResolveInProgress".loc)
                    }

                }
                
                Section {
                    Button(role:.destructive) {
                        Task { await removeContainer() }
                    } label: {
                        Text("lc.container.removeContainer".loc)
                    }
                }
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("lc.common.error".loc, isPresented: $errorShow){
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
        } message: {
            Text(successInfo)
        }
        
        .alert("lc.container.removeContainer".loc, isPresented: $removeContainerAlert.show) {
            Button(role: .destructive) {
                removeContainerAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeContainerAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeContainerDesc".loc)
        }
        
        .alert("lc.container.deleteData".loc, isPresented: $deleteDataAlert.show) {
            Button(role: .destructive) {
                deleteDataAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                deleteDataAlert.close(result: false)
            }
        } message: {
            Text("lc.container.deleteDataDesc".loc)
        }
        
        .alert("lc.settings.cleanKeychain".loc, isPresented: $removeKeychainAlert.show) {
            Button(role: .destructive) {
                removeKeychainAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeKeychainAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeKeychainDesc".loc)
        }
        .onAppear() {
            container.reloadInfoPlist()
            if let spoofedIDFV = container.spoofedIdentifier {
                typingIDFV = spoofedIDFV
            }
            settingsBundle = delegate.getSettingsBundle()
            runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName)
            inUse = runningLC != nil
        }
        .onDisappear {
            // 离开页面时把未按回车的改动存回去（两个输入框原来
            // 只在 onSubmit 写回，直接返回改动就丢了）。
            // 写回就是 onSubmit 调的同款轻量保存（只写容器元数据、
            // 不改目录名），进偏好设置子页面时也会触发，幂等、无害。
            // IDFV 只在改过且是合法 UUID 时存：非法输入在离开时
            // 静默丢弃（提交时的报错通道还在），免得在正在消失的
            // 视图上弹 alert；在用容器时 saveContainer 会拒存，
            // 报错 alert 同样可能弹不出，改动丢弃，与原来一致。
            if typingContainerName != container.name {
                container.name = typingContainerName
                saveContainer()
            }
            if !typingIDFV.isEmpty, typingIDFV != (container.spoofedIdentifier ?? ""), UUID(uuidString: typingIDFV) != nil {
                saveIDFV()
            }
        }
        
    }
    
    func saveIDFV() {
        guard let newIDFV = UUID(uuidString: typingIDFV) else {
            errorInfo = "lc.container.invalidIDFV".loc
            errorShow = true
            return
        }
        container.spoofedIdentifier = newIDFV.uuidString
        delegate.saveContainer(container: container)
    }

    func saveContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        
        delegate.saveContainer(container: container)
    }
    
    func openDataFolder() {
        // 文件夹名含空格时 URL(string:) 直接返回 nil，原来
        // url! 强解包点一下就闪退；先 percent-encoding 再拼，
        // 拼不出走现有错误提示通道，不强解包。
        guard let encodedName = container.folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string:"shareddocuments://\(LCPath.dataPath.path)/\(encodedName)") else {
            errorInfo = "无法打开数据文件夹"
            errorShow = true
            return
        }
        UIApplication.shared.open(url)
    }
    
    func setAsDefault() {
        delegate.setDefaultContainer(container: container)
    }
    
    func removeContainer() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        // 锁是客在 bootstrap 时才写：启动/签名进行中（宿主侧，
        // 锁还没写）删容器，客会起进已删文件夹、报错或重建空
        // 容器。宿主侧现成状态：模型正在启动或签名中，且选中的
        // 正是本容器时拦住；删的是同 App 别的容器不拦（启动
        // 只用选中那个）。不新造锁基础设施。
        if isOwningAppLaunching() {
            errorInfo = "App 正在启动或签名中，稍后再删。"
            errorShow = true
            return
        }
        guard let ans = await removeContainerAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            try fm.removeItem(at: container.containerURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    /// 本容器所属 App 是否正在用本容器启动/签名（S2 竞态口子）：
    /// 宿主侧现成状态，不新造锁。isAppRunning 覆盖整个宿主侧启动
    /// 窗口（含签名），isSigningInProgress 覆盖签名段；只认选中
    /// 容器就是本容器的那一个模型，别的容器不误拦。
    private func isOwningAppLaunching() -> Bool {
        guard let app = sharedModel.apps.first(where: { $0.uiContainers.contains { $0.folderName == container.folderName } }) else {
            return false
        }
        guard app.uiSelectedContainer?.folderName == container.folderName else {
            return false
        }
        return app.isAppRunning || app.isSigningInProgress
    }

    func unbindContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        if isOwningAppLaunching() {
            errorInfo = "App 正在启动或签名中，稍后再操作。"
            errorShow = true
            return
        }

        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    func cleanUpKeychain() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        if isOwningAppLaunching() {
            errorInfo = "App 正在启动或签名中，稍后再操作。"
            errorShow = true
            return
        }
        guard let ans = await removeKeychainAlert.open(), ans else {
            return
        }
        
        LCUtils.removeAppKeychain(dataUUID: container.folderName)
    }
    
    func deleteData() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        if isOwningAppLaunching() {
            errorInfo = "App 正在启动或签名中，稍后再操作。"
            errorShow = true
            return
        }
        guard let ans = await deleteDataAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: container.containerURL, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == "LCContainerInfo.plist" {
                    continue
                }
                try fm.removeItem(at: file)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}
