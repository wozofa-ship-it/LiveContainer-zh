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
    @State private var typingProxyHost: String = ""
    @State private var typingProxyPort: String = ""
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
                                // 3.8.566（L97）：在用时 saveContainer 拒存，
                                // 但名字已在上面改了内存——提示报错的同时
                                // 列表却显示新名，重启又变回旧名；存失败
                                // 时把内存名字与输入框都还原，拒存就是没改。
                                let oldName = container.name
                                container.name = typingContainerName
                                if !saveContainer() {
                                    container.name = oldName
                                    typingContainerName = oldName
                                }
                            }
                    }
                    HStack {
                        Text("lc.container.containerFolderName".loc)
                        Spacer()
                        Text(container.folderName)
                            .foregroundStyle(.gray)
                    }
                    Toggle(isOn: Binding(
                        get: { container.isolateAppGroup },
                        set: { newValue in
                            // 3.8.900（L569-6）：在用时拒存，内存里的开关也必须还原——
                            // Toggle 先写内存、onChange 再调 saveContainer()，在用时
                            // saveContainer() 拒存报错，但开关已留在开的位置（L97
                            // 只修了名字栏，三个开关漏了同款）；reloadInfoPlist()
                            // 只重读 infoDict、不回写 @Published 属性，重进页面开关
                            // 仍显示开、重启才变回关，用户以为已隔离、其实下次启动
                            // 仍按旧配置跑。存失败就地把开关拨回旧值（同步做，
                            // 不走 onChange，无往复触发；didSet 已生成的伪装值
                            // 留着无害——下次成功打开时复用同一套固定值）。
                            let oldValue = container.isolateAppGroup
                            container.isolateAppGroup = newValue
                            if !saveContainer() {
                                container.isolateAppGroup = oldValue
                            }
                        }
                    )) {
                        Text("lc.container.isolateAppGroup".loc)
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
                    Toggle(isOn: Binding(
                        get: { container.spoofIdentifierForVendor },
                        set: { newValue in
                            // 3.8.900（L569-6）：同 isolateAppGroup——在用时拒存，开关拨回旧值。
                            let oldValue = container.spoofIdentifierForVendor
                            container.spoofIdentifierForVendor = newValue
                            if !saveContainer() {
                                container.spoofIdentifierForVendor = oldValue
                            }
                        }
                    )) {
                        Text("lc.container.spoofIdentifierForVendor".loc)
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
                    Toggle(isOn: Binding(
                        get: { container.spoofDeviceFingerprint },
                        set: { newValue in
                            // 3.8.900（L569-6）：同 isolateAppGroup——在用时拒存，开关拨回旧值。
                            let oldValue = container.spoofDeviceFingerprint
                            container.spoofDeviceFingerprint = newValue
                            if !saveContainer() {
                                container.spoofDeviceFingerprint = oldValue
                            }
                        }
                    )) {
                        Text("lc.container.spoofDeviceFingerprint".loc)
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
                        HStack {
                            Text("lc.container.spoofedRegion".loc)
                            Spacer()
                            Text(container.spoofedRegion ?? "")
                                .foregroundStyle(.gray)
                        }
                        // 每分身单独代理：用户自己填 host + 端口，
                        // 留空 = 不走代理。填错代理会让客端联网断，
                        // 只在 host 非空且端口是 1...65535 时存。
                        HStack {
                            Text("lc.container.spoofedProxyHost".loc)
                            Spacer()
                            TextField("lc.container.spoofedProxyHostPlaceholder".loc, text: $typingProxyHost)
                                .multilineTextAlignment(.trailing)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .onSubmit {
                                    saveProxy()
                                }
                        }
                        HStack {
                            Text("lc.container.spoofedProxyPort".loc)
                            Spacer()
                            TextField("lc.container.spoofedProxyPortPlaceholder".loc, text: $typingProxyPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .onSubmit {
                                    saveProxy()
                                }
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
                    // 3.8.900（L570-4）：解析是同步的（LCContainer
                    // convenience init 里当场解，无异步解析路、
                    // bookmarkResolveContinuation 全仓无写点），
                    // 走到这里就是书签在、URL 解不出 = 已死，
                    // 不是“正在解析”——原来按 bookmarkResolved
                    // 分两句，C1 把死书签的标志改回 false 后，
                    // 死书签会错显示“正在解析”、用户会一直等。
                    // 死书签只有“不可用”这一句。
                    Text("lc.container.externalStorageUnavailable".loc)

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
        // 3.8.589（L121）：同一视图挂多个 .alert/.confirmationDialog 只有最后一个生效——
        // SwiftUI 同一分支只认最外层一个弹窗（sarunw 实证，L120 同款）。
        // 各挪一个 background 叶子、各占一条分支，宿主链上不再留弹窗类修饰符；触发点与按钮一字不动。
        .background(
            EmptyView()
                .alert("lc.common.error".loc, isPresented: $errorShow){
                } message: {
                    Text(errorInfo)
                }
        )
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
                .alert("lc.common.success".loc, isPresented: $successShow){
                } message: {
                    Text(successInfo)
                }
        )
        
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
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
        )
        
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
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
        )
        
        // 3.8.589（L121）：同款——也挪 background 叶子。
        .background(
            EmptyView()
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
        )
        .onAppear() {
            container.reloadInfoPlist()
            if let spoofedIDFV = container.spoofedIdentifier {
                typingIDFV = spoofedIDFV
            }
            typingProxyHost = container.spoofedProxyHost ?? ""
            typingProxyPort = container.spoofedProxyPort > 0 ? "\(container.spoofedProxyPort)" : ""
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
                // 3.8.566（L97）：同 onSubmit——在用时拒存，内存名字
                // 却已改了，离开页面后列表显示新名、重启变回旧名，
                // 注释说的“改动丢弃”并没有丢弃；存失败时还原内存名。
                let oldName = container.name
                container.name = typingContainerName
                if !saveContainer() {
                    container.name = oldName
                }
            }
            if !typingIDFV.isEmpty, typingIDFV != (container.spoofedIdentifier ?? ""), UUID(uuidString: typingIDFV) != nil {
                saveIDFV()
            }
            if typingProxyHost != (container.spoofedProxyHost ?? "") || typingProxyPort != (container.spoofedProxyPort > 0 ? "\(container.spoofedProxyPort)" : "") {
                saveProxy(silent: true)
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

    func saveProxy(silent: Bool = false) {
        // host 留空 = 不走代理（同时清端口）；端口只认 1...65535。
        // 3.8.900（L568-22）：端口非法时原来直接 return，host 也
        // 跟着静默丢了——用户填了 host、端口留空/填 99999，按回车
        // 或离页后重进 host 栏是空的，全程无任何提示（端口栏是
        // numberPad、无回车键，onSubmit 主要靠 host 栏回车或离页
        // 触发，留空端口 `Int("")` 得 0，正好撞上这条 return）。
        // 提交路（onSubmit）非法时报出来、保留输入框内容供修正；
        // 离开路（onDisappear）仍静默丢弃，与 IDFV 离开时丢弃非法
        // 输入同款。
        let host = typingProxyHost.trimmingCharacters(in: .whitespaces)
        let port = Int(typingProxyPort.trimmingCharacters(in: .whitespaces)) ?? 0
        if host.isEmpty {
            container.spoofedProxyHost = nil
            container.spoofedProxyPort = 0
        } else if (1...65535).contains(port) {
            container.spoofedProxyHost = host
            container.spoofedProxyPort = port
        } else {
            if !silent {
                errorInfo = "代理端口须为 1–65535".loc
                errorShow = true
            }
            return
        }
        delegate.saveContainer(container: container)
    }

    // 3.8.566（L97）：拒存时返回 false——名字先改内存再调保存，
    // 在用时保存被拒、内存里的名字却已改了，列表当场显示新名、
    // 重启又变回旧名，拒存等于没拒；调用方存失败时把名字还原。
    @discardableResult
    func saveContainer() -> Bool {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return false
        }
        
        delegate.saveContainer(container: container)
        return true
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
        // 3.8.579（L399-1）：本函数从按钮的裸 Task 调来（:229/:249）、不在主 actor 上；errorInfo/errorShow 是 @State（:38-39），dismiss 与 delegate.unbindContainer 写 @Published（LCAppSettingsView:1417），离主线程写报 Publishing changes、容器列表可能不刷新、详情页可能关不掉（L40/L44 同款——L40 只修了新建/导入两路，删容器这路漏了）。isOwningAppLaunching() 读 sharedModel.apps 数组（L383-1 同款）也一并回主线程取；删文件本身留外面。deleteData/cleanUpKeychain 同款。
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            await MainActor.run {
                errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
                errorShow = true
            }
            return
        }
        // 锁是客在 bootstrap 时才写：启动/签名进行中（宿主侧，
        // 锁还没写）删容器，客会起进已删文件夹、报错或重建空
        // 容器。宿主侧现成状态：模型正在启动或签名中，且选中的
        // 正是本容器时拦住；删的是同 App 别的容器不拦（启动
        // 只用选中那个）。不新造锁基础设施。
        if await MainActor.run(body: { isOwningAppLaunching() }) {
            await MainActor.run {
                errorInfo = "App 正在启动或签名中，稍后再删。"
                errorShow = true
            }
            return
        }
        guard let ans = await removeContainerAlert.open(), ans else {
            return
        }
        do {
            // 3.8.900（L566-3）：外置容器（storageBookMark != nil）是用户
            // 自管的外置文件夹，本来就不该由本 App 删盘——只解绑、不删文件。
            // 书签已死时 containerURL 还会回落到本地 dataPath/<folderName>，
            // removeItem 必抛（外置夹根本不在那里），unbind 一行都走不到、
            // 条目永远删不掉；同名本地夹恰好存在时还会删错。本地容器才删盘。
            if container.storageBookMark == nil {
                let fm = FileManager.default
                try fm.removeItem(at: container.containerURL)
            }
        } catch {
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        await MainActor.run {
            dismiss()
            delegate.unbindContainer(container: container)
        }
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
        // 3.8.579（L399-1）：同 removeContainer，裸 Task 调来（:222）、@State 写与 isOwningAppLaunching() 的数组读回主线程；钥匙串操作本身留外面（SecItem 线程安全，G3 另案）。
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            await MainActor.run {
                errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
                errorShow = true
            }
            return
        }
        if await MainActor.run(body: { isOwningAppLaunching() }) {
            await MainActor.run {
                errorInfo = "App 正在启动或签名中，稍后再操作。"
                errorShow = true
            }
            return
        }
        guard let ans = await removeKeychainAlert.open(), ans else {
            return
        }
        
        LCUtils.removeAppKeychain(dataUUID: container.folderName, keychainGroupId: container.keychainGroupId)
        // 3.8.900（L566-4）：成功弹窗是死代码——successShow 全文件只有
        // 声明与挂载两处，从没人置 true，清理完页面纹丝不动、用户分
        // 不清成功还是没点上；成功了就报一声，复用已挂好的弹窗。
        await MainActor.run {
            successInfo = "钥匙串已清理"
            successShow = true
        }
    }
    
    func deleteData() async {
        // 3.8.579（L399-1）：同 removeContainer，裸 Task 调来（:217）、@State 写与 isOwningAppLaunching() 的数组读回主线程；删文件本身留外面。
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            await MainActor.run {
                errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
                errorShow = true
            }
            return
        }
        if await MainActor.run(body: { isOwningAppLaunching() }) {
            await MainActor.run {
                errorInfo = "App 正在启动或签名中，稍后再操作。"
                errorShow = true
            }
            return
        }
        guard let ans = await deleteDataAlert.open(), ans else {
            return
        }
        // 3.8.900（L568-16）：外置容器点“删除数据”永远弹错——
        // 列目录/删文件全程没调 startAccessing，外置夹在沙盒
        // 外，contentsOfDirectory 直接抛错进 catch、数据一行
        // 都没删。L39 同款包一层；本地容器 bookmarkResolved
        // 为 false，不碰。须与 L568-12（解析带 scope）合用。
        let czfDidAccess = container.bookmarkResolved && container.containerURL.startAccessingSecurityScopedResource()
        defer { if czfDidAccess { container.containerURL.stopAccessingSecurityScopedResource() } }
        do {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: container.containerURL, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == "LCContainerInfo.plist" {
                    continue
                }
                try fm.removeItem(at: file)
            }
        } catch {
            await MainActor.run {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        // 3.8.900（L566-4）：同 cleanUpKeychain——成功弹窗死代码，删完
        // 不报一声；删完无错就是成功，报一声。
        await MainActor.run {
            successInfo = "数据已删除"
            successShow = true
        }
    }
}
