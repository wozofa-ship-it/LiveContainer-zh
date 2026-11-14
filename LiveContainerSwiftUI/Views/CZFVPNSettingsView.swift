// CZFVPNSettingsView.swift
// 模块页 VPN 分段：原设置页 VPN 区整段搬过来（3.8.328），设置页不再留。
// 状态机一字未动：节点/测速/订阅/核心状态全走 CZFVPNManager.shared（UserDefaults 落盘）+ 本页 @State；
// 搬家后只有这一份，设置页与模块页不再各存一份。
// 布局微调：原 DisclosureGroup 收起包装在专属页里没意义，拆掉——状态行（图标+“单App VPN”+核心状态）
// 留在 Section 顶部当状态行，其余内容原样。

import SwiftUI

struct CZFVPNSettingsView: View {
    @EnvironmentObject private var sharedModel: SharedModel

    // 报错/成功提示（本页自有；设置页那份留在设置页给证书等用）
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""

    @State var vpnCoreRunning = false
    @State var vpnStatusMessage: String?
    @State var vpnNewNodeText = ""
    @State var vpnSubURL: String = UserDefaults.standard.string(forKey: "CZFVPNSubscriptionURL") ?? ""
    @State var vpnSubBusy = false
    @State var showSubReplaceConfirm = false
    @State var pendingSubLinks: [String] = []
    @State var vpnNodes: [String] = []
    @State var vpnHostProxy = false
    @AppStorage("CZFVPNPrewarm") var vpnPrewarm = true
    @AppStorage("CZFVPNAutoRotate") var vpnAutoRotate = true
    @AppStorage("CZFVPNAutoStopMinutes") var vpnAutoStopMinutes = 10
    @State var vpnActiveIndex = 0
    @State var vpnPingResults: [Int: CZFVPNManager.CZFNodePingResult] = [:]
    // 3.8.518（L43）：内存测速结果是按下标记的，vpnPingResultNodes
    // 是记结果时那份节点列表快照；列表在外边被换过时下标已不对号，
    // refreshVPNState 与单测收尾先对快照、不对就清掉重建。
    @State var vpnPingResultNodes: [String] = []
    @State var vpnPingStaleIndices: Set<Int> = []
    @State var vpnSinglePinging = false
    @State var vpnSinglePingIndex: Int?
    @State var showDeleteActiveConfirm = false
    // 节点多选删除：长按行进多选（链接作键，导入换列表不错位），
    // 全选/删除选中/取消在这组状态上跑，删在用节点走已有确认框。
    @State var vpnNodeSelecting = false
    @State var vpnSelectedNodeLinks: Set<String> = []
    @State var pendingDeleteIndices: [Int] = []
    // 节点长按菜单（复制/编辑/别名/多选）+ 手动拖拽排序：
    // 编辑/别名走 textFieldAlert（iOS 15 可用；alert 内
    // TextField 需 iOS 16，部署目标 15.0 不可用）。
    @State var vpnEditNodeIndex: Int? = nil
    @State var vpnEditNodeText = ""
    @State var vpnEditNodeShow = false
    @State var vpnAliasNodeLink: String? = nil
    @State var vpnAliasText = ""
    @State var vpnAliasShow = false
    @State var vpnReordering = false
    // 订阅自动更新：开关 + 上次拉取时间（超 24 小时才拉，
    // 进 VPN 页检查一次，不每次进都拉）。
    @AppStorage("CZFVPNSubAutoUpdate") var vpnSubAutoUpdate = false
    // 清理不通确认框
    @State var showClearFailedConfirm = false
    @State var pendingClearFailedCount = 0
    @State var vpnPinging = false
    @State var vpnPingRejected = false
    // 单测被核心占用拒写过的节点链接（CZF，3.8.237）：
    // 核心在跑时 pingBatch 被 libXray 生命周期锁拒掉，
    // 旧值与·旧都保留、用户在行上看不出任何变化；
    // 用链接集合标记（不用下标，删/排/导都不错位），
    // 行上直接显示“核心占用”，不再让用户猜。
    // 单测成功写回时清该条、整表成功时全清；只存会话，
    // 不落盘、不参与清理/排序判定（绝不冒充测速结果）。
    @State var vpnSingleRejectedLinks: Set<String> = []
    @State var vpnPingDone = 0
    @State var vpnPingTotal = 0
    @State var vpnPingPhase = "测速"
    @State var vpnPrewarmSuppressed = false
    @State private var showVPNHelp = false
    // O-7：查看核心日志（只读展示尾部，脱敏后显示）
    @State var showCoreLog = false
    @State var coreLogText = ""

    /// 任一出现）：批量操作行只在此时才出现，平时不占一行。
    /// 清理只认网络失败——转换失败（不支持）的不算，避免只剩
    /// 不支持节点时出现一行空按钮。
    private var hasVPNBatchActions: Bool {
        vpnPingResults.contains(where: { $0.value.success && $0.key != vpnActiveIndex })
            || vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex })
            || vpnPingResults.count > 1
    }

    // 已开 VPN 的 App 汇总（可见 + 隐藏）：按 CZFVPNManager
    // 的 per-App 开关读，VPN 区里一行显示名字。
    private var vpnEnabledApps: [LCAppModel] {
        (sharedModel.apps + sharedModel.hiddenApps).filter { CZFVPNManager.isEnabled(for: $0.appInfo) }
    }

    // 订阅自动更新上次拉取时间的显示
    private var subAutoUpdateLastText: String {
        let last = UserDefaults.standard.double(forKey: "CZFVPNSubAutoUpdateLast")
        if last <= 0 { return "还没自动更新过，进 VPN 页时检查" }
        return "上次更新：\(Date(timeIntervalSince1970: last).formatted(date: .numeric, time: .shortened))"
    }

    var body: some View {
        Form {
            vpnSection
        }
        .alert("lc.common.error".loc, isPresented: $errorShow){
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
        } message: {
            Text(successInfo)
        }
        .confirmationDialog("替换全部节点？", isPresented: $showSubReplaceConfirm, titleVisibility: .visible) {
            Button("替换为订阅的 \(pendingSubLinks.count) 个节点", role: .destructive) {
                applySubscriptionLinks(pendingSubLinks)
                pendingSubLinks = []
            }
            Button("合并导入（只加新的）") {
                mergeSubscriptionLinks(pendingSubLinks)
                pendingSubLinks = []
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingSubLinks = []
            }
        } message: {
            Text("替换会把当前 \(vpnNodes.count) 个节点（包括手动添加的）整体换掉，此操作不可恢复；合并只追加订阅里没有的节点，保留手填节点")
        }
        .alert("删除在用节点？", isPresented: $showDeleteActiveConfirm) {
            Button("删除并停核心", role: .destructive) {
                for i in pendingDeleteIndices.sorted(by: >) {
                    CZFVPNManager.shared.removeNode(at: i)
                }
                pendingDeleteIndices = []
                vpnSelectedNodeLinks = []
                vpnNodeSelecting = false
                vpnPingResults = [:]
                refreshVPNState()
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                pendingDeleteIndices = []
            }
        } message: {
            Text("删掉在用节点后核心会停掉，不会自动切到别的节点继续跑")
        }
        .textFieldAlert(
            isPresented: $vpnEditNodeShow,
            title: "编辑节点链接",
            text: $vpnEditNodeText,
            placeholder: "vless://…",
            action: { newText in
                if let idx = vpnEditNodeIndex, let text = newText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if CZFVPNManager.shared.updateNode(at: idx, with: text) {
                        vpnPingResults = [:]
                        refreshVPNState()
                    } else {
                        errorInfo = "节点已存在，未重复添加"
                        errorShow = true
                    }
                }
                vpnEditNodeIndex = nil
            },
            actionCancel: { _ in
                vpnEditNodeIndex = nil
            }
        )
        .textFieldAlert(
            isPresented: $vpnAliasShow,
            title: "节点别名",
            text: $vpnAliasText,
            placeholder: "给节点起个名字",
            action: { newText in
                if let link = vpnAliasNodeLink {
                    CZFVPNManager.setNodeAlias(newText, for: link)
                    refreshVPNState()
                }
                vpnAliasNodeLink = nil
            },
            actionCancel: { _ in
                vpnAliasNodeLink = nil
            }
        )
        .onAppear {
            refreshVPNState()
            autoUpdateSubscriptionIfNeeded()
        }
        .onChange(of: vpnSubAutoUpdate) { newValue in
            if newValue {
                autoUpdateSubscriptionIfNeeded()
            }
        }
        // 切回前台刷新核心状态：核心在后台被自动停、被别的
        // App 起停后，按钮还是旧状态，下一按钮一刷新才翻出来、
        // 看起来像那个按钮切的；切回前台就刷新，按钮先对上真实状态。
        // 测速中刷新不翻核心按钮（见 refreshVPNState 里的测速中守卫），不会打断测速。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshVPNState()
        }
    }


    @ViewBuilder private var vpnSection: some View {
        Section {
            czfVPNSectionHead
            czfVPNNodeList
            czfVPNCoreRow
            czfVPNBatchAndToggles
        } footer: {
        // 原来这里是一整段 400 多字说明，常驻占十几行。
        // 改成默认只剩一行入口，点开才看精简版：关键意思
        // 都还在（切换/删除、订阅替换、测速、开 VPN、预热、
        // 源下载走节点、自动停、最小化不算关），但平时
        // 模块页不再被这段顶下去。
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showVPNHelp.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text("VPN 说明")
                    Image(systemName: showVPNHelp ? "chevron.up" : "chevron.down")
                }
            }
            .font(.footnote)
            .buttonStyle(.plain)
            if showVPNHelp {
                Text("点节点行切换（核心在跑时立即生效），左滑删除；订阅导入会整体替换节点列表，更新后重导一次。\n测延迟是真实请求往返毫秒数，不切换核心，通的节点先显示；测延迟会在核心在跑时先停核心、测完重启原来那条；核心没在跑时直接测、不启动。\n给 App 开 VPN：去该 App 设置页打开「VPN 打开（内置节点）」；标记的 App 打开时核心自启，全部关掉后按上面分钟数自停，期间重开会取消这次自停。\n预热开着进 App 就先热好核心；源和下载走节点只对境外源有用。\n最小化不算关，核心继续跑。\n节点行会显示协议（vless/vmess/trojan/ss/socks/hysteria2/tuic 等）；转换器只认这几类，未列出的链接会标“不支持”——不是网络不通，“清理不通”不会删它们。\n绕法：可以把出站写成原始 Xray JSON 当节点粘贴（转换器会保留其 outbounds），名字会显示成“节点”；测速与启动都走同一转换，JSON 节点同样能测。\n节点自动轮换开着时，核心在跑的 App 连续失败就自动按列表顺序换下一个支持的节点并重启核心，一圈都不通就停下来等手动处理。")
            }
        }
        }
    }

    // O-14：由 vpnSection 拆出，只拆表达式不改逻辑、不改显示顺序。
    @ViewBuilder private var czfVPNSectionHead: some View {
            HStack {
                // 3.8.282：VPN 栏加美化图标（用户亲令）：跟数据管理、
                // 保活等行一样挂彩色图标，不然整行只有字、太素
                LCSettingsIcon(systemName: "shield.fill", color: .green)
                Text("单App VPN")
                Spacer()
                Text(vpnCoreRunning ? "核心运行中" : "核心未启动")
                    .font(.footnote)
                    .foregroundStyle(.gray)
            }
            HStack {
                TextField("粘贴节点链接（vless://…）", text: $vpnNewNodeText)
                .textInputAutocapitalization(.never)
            Button("添加") {
                // 重复添加不再静默：addNode 返回 false
                // 时提示已存在，输入框留着、不清结果。
                if CZFVPNManager.shared.addNode(vpnNewNodeText) {
                    vpnNewNodeText = ""
                    vpnPingResults = [:]
                    refreshVPNState()
                } else {
                    errorInfo = "节点已存在，未重复添加"
                    errorShow = true
                }
            }
            .disabled(vpnNewNodeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
        }
        HStack {
            TextField("粘贴订阅地址（https://…）", text: $vpnSubURL)
                .textInputAutocapitalization(.never)
            Button(vpnSubBusy ? "拉取中…" : "导入订阅") {
                vpnSubBusy = true
                CZFVPNManager.fetchSubscriptionLinks(urlString: vpnSubURL) { result in
                    DispatchQueue.main.async {
                        vpnSubBusy = false
                        switch result {
                        case .success(let links):
                            // 整体替换是破坏性操作：列表里有
                            // 手填节点时先确认再替换（原来点
                            // 一下直接全换，手填的瞬间没了）；
                            // 列表为空没东西可丢，直接导入
                            if vpnNodes.isEmpty {
                                applySubscriptionLinks(links)
                            } else {
                                pendingSubLinks = links
                                showSubReplaceConfirm = true
                            }
                        case .failure(let error):
                            errorInfo = error.localizedDescription
                            errorShow = true
                        }
                    }
                }
            }
            .disabled(vpnSubBusy || vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vpnPinging || vpnSinglePinging)
        }
        // 订阅自动更新：开着时进 VPN 页检查，上次拉取超 24
        // 小时才重新拉（只追加新节点，保留手填节点）。
        Toggle(isOn: $vpnSubAutoUpdate) {
            Text("订阅自动更新")
        }
        if vpnSubAutoUpdate {
            Text(subAutoUpdateLastText)
                .font(.footnote)
                .foregroundStyle(.gray)
        }
        // 已开 VPN 的 App 汇总：按 per-App 开关读，只汇总、
        // 不改开关（改开关去各 App 设置页）。
        if vpnEnabledApps.isEmpty {
            Text("暂无 App 开启 VPN")
                .font(.footnote)
                .foregroundStyle(.gray)
        } else {
            Text("已开 VPN 的 App（\(vpnEnabledApps.count)）：\(vpnEnabledApps.map { $0.appInfo.displayName() ?? $0.appInfo.bundleIdentifier() ?? "?" }.joined(separator: "、"))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // O-14：由 vpnSection 拆出，只拆表达式不改逻辑、不改显示顺序。
    @ViewBuilder private var czfVPNNodeList: some View {
        // 手动拖拽排序：点“排序”出现拖动柄，拖完点“完成”；
        // 活动节点按内容跟随，不重启核心。
        HStack {
            Text("节点")
                .font(.headline)
            Spacer()
            Button(vpnReordering ? "完成" : "排序") {
                vpnReordering.toggle()
            }
            .buttonStyle(.borderless)
        }
        ForEach(Array(vpnNodes.enumerated()), id: \.offset) { index, link in
            Button {
                if vpnNodeSelecting {
                    if vpnSelectedNodeLinks.contains(link) {
                        vpnSelectedNodeLinks.remove(link)
                    } else {
                        vpnSelectedNodeLinks.insert(link)
                    }
                } else {
                    CZFVPNManager.shared.setActiveNode(at: index)
                    refreshVPNState()
                }
            } label: {
                HStack(spacing: 8) {
                    if vpnNodeSelecting {
                        Image(systemName: vpnSelectedNodeLinks.contains(link) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vpnSelectedNodeLinks.contains(link) ? Color.blue : Color.secondary)
                    }
                    CZFVPNNodeLabel(
                        link: link,
                        ping: vpnPingResults[index],
                        isActive: index == vpnActiveIndex,
                        coreRunning: vpnCoreRunning,
                        pinging: vpnPinging,
                        isSinglePingTarget: vpnSinglePingIndex == index,
                        isRejected: vpnSingleRejectedLinks.contains(link),
                        isStale: vpnPingStaleIndices.contains(index)
                    )
                }
            }
            // 长按菜单：复制链接/编辑链接/自定义别名/多选。
            // 原来长按直接进多选，菜单里留“多选”同款入口；
            // 复测仍走右滑，不动。
            .contextMenu {
                Button {
                    UIPasteboard.general.string = link
                    successInfo = "节点链接已复制"
                    successShow = true
                } label: {
                    Label("复制链接", systemImage: "doc.on.doc")
                }
                Button {
                    vpnEditNodeIndex = index
                    vpnEditNodeText = link
                    vpnEditNodeShow = true
                } label: {
                    Label("编辑链接", systemImage: "pencil")
                }
                Button {
                    vpnAliasNodeLink = link
                    vpnAliasText = CZFVPNManager.nodeAlias(for: link) ?? ""
                    vpnAliasShow = true
                } label: {
                    Label("自定义别名", systemImage: "tag")
                }
                Button {
                    if !vpnNodeSelecting {
                        vpnNodeSelecting = true
                    }
                    vpnSelectedNodeLinks.insert(link)
                } label: {
                    Label("多选", systemImage: "checkmark.circle")
                }
            }
            // 右滑测速：整表测速太慢时只测这一条，
            // 与原长按复测同一入口；左滑删除不动。
            // allowsFullSwipe 关掉：测速要占 isPinging、
            // 挡核心切换，滑满就触发太容易误触。
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    startSinglePing(index)
                } label: {
                    Label("测速", systemImage: "speedometer")
                }
                .tint(.blue)
                .disabled(vpnPinging || vpnSinglePinging)
            }
            // 3.8.317：左滑删除改走 swipeActions 的删除钮——
            // 原来的 .onDelete 删在用节点时只弹确认框、不删
            // 数据，List 底层 UICollectionView 却已按“删了
            // 1 条”去算（7-1=6），数据源仍是 7 条，直接报
            // Invalid update（用户 2026-11-06 21:42 真机实
            // 证）。swipeActions 的按钮不触发 List 自动删，
            // 点了才由代码删数据，确认框再弹也安全。
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    guard !vpnPinging && !vpnSinglePinging else { return }
                    // 删在用节点先弹确认：manager 侧删在用
                    // 节点已改成停核心不自动切，界面再确认
                    // 一次，免得左滑手误把在用节点删了。
                    if index == vpnActiveIndex {
                        pendingDeleteIndices = [index]
                        showDeleteActiveConfirm = true
                    } else {
                        CZFVPNManager.shared.removeNode(at: index)
                        vpnPingResults = [:]
                        refreshVPNState()
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(vpnPinging || vpnSinglePinging)
            }
        }
        // 手动拖拽排序：上面“排序”开着时出拖动柄，
        // 拖完 replaceNodeOrder 写回，活动节点按内容跟随。
        // onMove 必须直接挂在 ForEach 上（3.8.320 构建
        // #370 红字：挂在 .disabled/.environment 之后，
        // 类型变成 some View 就没有 onMove 了）。
        .onMove { source, destination in
            var links = vpnNodes
            links.move(fromOffsets: source, toOffset: destination)
            CZFVPNManager.shared.replaceNodeOrder(links)
            refreshVPNState()
        }
        // 测速中节点行置灰：测速中点节点行只会把勾
        // 先动、核心切换被挡下测完才补跑，看起来
        // 像切了其实还没切；置灰后测速中点不动，
        // 测完再点才是真切。单节点复测同理。
        .disabled(vpnPinging || vpnSinglePinging)
        .environment(\.editMode, vpnReordering ? .constant(.active) : .constant(.inactive))
        // 多选删除操作条：只在长按进多选后出现；全选按链接集合算，
        // 删选中走 deleteSelectedVPNNodeLinks（在用节点走确认框）。
        if vpnNodeSelecting {
            HStack {
                Button(vpnSelectedNodeLinks == Set(vpnNodes) && !vpnNodes.isEmpty ? "取消全选" : "全选") {
                    if vpnSelectedNodeLinks == Set(vpnNodes) {
                        vpnSelectedNodeLinks = []
                    } else {
                        vpnSelectedNodeLinks = Set(vpnNodes)
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("删除选中 (\(vpnSelectedNodeLinks.count))") {
                    deleteSelectedVPNNodeLinks()
                }
                .disabled(vpnSelectedNodeLinks.isEmpty)
                .foregroundStyle(Color.red)
                .buttonStyle(.borderless)
                Button("取消") {
                    vpnNodeSelecting = false
                    vpnSelectedNodeLinks = []
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // O-14：由 vpnSection 拆出，只拆表达式不改逻辑、不改显示顺序。
    @ViewBuilder private var czfVPNCoreRow: some View {
        HStack {
            Button(vpnCoreRunning ? "停止核心" : "启动核心") {
                CZFVPNManager.shared.noteManualCoreToggle(started: !vpnCoreRunning)
                if vpnCoreRunning {
                    CZFVPNManager.shared.stop()
                } else {
                    _ = CZFVPNManager.shared.start()
                }
                refreshVPNState()
            }
            // 测速中置灰：测速中亲手起停核心会和测速
            // 的 deferred 逻辑插队，状态容易翻；测速
            // 本身又不切核心，测速中起停没有意义，
            // 测完再点。
            .disabled(vpnPinging || vpnSinglePinging)
            .buttonStyle(.borderless)
            Button(vpnPinging ? (vpnPingTotal > 0 ? "\(vpnPingPhase) \(vpnPingDone)/\(vpnPingTotal)" : "测速中…") : "测延迟") {
                startVPNPing()
            }
            .disabled(vpnPinging || vpnSinglePinging || vpnNodes.isEmpty)
            .buttonStyle(.borderless)
            Spacer()
            Text(vpnCoreRunning ? "核心运行中" : (vpnStatusMessage ?? "核心未启动"))
                .font(.footnote)
                .foregroundStyle(.gray)
        }
        .onAppear {
            refreshVPNState()
        }
        // O-7：查看核心日志（只读展示尾部 N 行，脱敏后显示；
        // 日志落盘在 Documents/singbox/sing-box.log 与
        // Documents/xray/，见 CZFVPNManager.coreLogTail）。
        Button("查看核心日志") {
            loadCoreLog()
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showCoreLog) {
            NavigationView {
                ScrollView {
                    Text(coreLogText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("核心日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showCoreLog = false }
                    }
                }
            }
        }
    }

    // O-14：由 vpnSection 拆出，只拆表达式不改逻辑、不改显示顺序。
    @ViewBuilder private var czfVPNBatchAndToggles: some View {
        // 测完后的批量操作单独放一行：原来启动/测延迟/
        // 切最快/清理/排序/被拒提示/状态全挤在一行，
        // 按钮一多就互相挤压截断；拆开后主操作行永远
        // 只有两个按钮加状态，批量行只在有操作时出现。
        if hasVPNBatchActions {
        HStack {
            // 测完后一键切到最快的（只认测通的节点；
            // 已经是最快时不显示，省得误会）
            if let fastest = vpnPingResults.filter({ $0.value.success }).min(by: { $0.value.delay < $1.value.delay }), fastest.key != vpnActiveIndex {
                Button("切到最快") {
                    CZFVPNManager.shared.setActiveNode(at: fastest.key)
                    refreshVPNState()
                }
                .disabled(vpnPinging || vpnSinglePinging)
                .buttonStyle(.borderless)
            }
            // 测完后一键清理不通的节点：只删明确测
            // 出网络不通的、且不是当前在用节点的——在用
            // 节点即使某次测速失败也不删（核心在跑且
            // 实际上网是更强的证据，见上面「在用」
            // 的例外）；转换失败（不支持）的也不删——
            // 它们不是网络不通，删了等于删协议，留着等
            // 换协议或走原始 JSON 出站绕法。用
            // replaceAllNodes 一次替换，活动节点按内容
            // 跟随、不重启核心。
            if vpnPingResults.contains(where: { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }) {
                Button("清理不通") {
                    pendingClearFailedCount = vpnPingResults.filter { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }.count
                    showClearFailedConfirm = true
                }
                // 被拒时不再禁清理：被拒结果已不再覆写
                // 界面和缓存，清理按上次真测结果走；
                // 测速中仍禁，免得按还没重试完的临时
                // 失败删节点。
                .disabled(vpnPinging || vpnSinglePinging)
                .buttonStyle(.borderless)
            }
            // 测完后按延迟从低到高重排节点列表（不通
            // 的沉底、没测到的最后），在用节点固定
            // 在原位置不动、只排其余节点，活动节点
            // 按内容跟随、不重启核心。以前在用节点
            // 测速失败也会按不通沉底，列表顺序变了、
            // 容易误会成在用节点被换了。
            if vpnPingResults.count > 1 {
                Button("按延迟排序") {
                    let links = CZFVPNManager.shared.nodeLinks
                    let activeIdx = vpnActiveIndex
                    let activeLink: String? = links.indices.contains(activeIdx) ? links[activeIdx] : nil
                    let rest = links.enumerated().filter { $0.offset != activeIdx }.sorted { a, b in
                        let ka = vpnPingResults[a.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                        let kb = vpnPingResults[b.offset].map { $0.success ? $0.delay : Int.max - 1 } ?? Int.max
                        return ka < kb
                    }.map { $0.element }
                    var sorted = rest
                    if let activeLink {
                        sorted.insert(activeLink, at: min(activeIdx, sorted.count))
                    }
                    CZFVPNManager.shared.replaceNodeOrder(sorted)
                    vpnPingResults = [:]
                    refreshVPNState()
                }
                .disabled(vpnPinging || vpnSinglePinging)
                .buttonStyle(.borderless)
            }
        }
        // 清理不通先确认：删节点不可恢复，点一下就删
        // 太容易手误；确认框里写清删几个、在用与不支持的不删。
        .alert("清理不通的节点？", isPresented: $showClearFailedConfirm) {
            Button("清理 \(pendingClearFailedCount) 个", role: .destructive) {
                let failed = Set(vpnPingResults.filter { !$0.value.success && !$0.value.conversionFailed && $0.key != vpnActiveIndex }.map { $0.key })
                let kept = CZFVPNManager.shared.nodeLinks.enumerated().filter { !failed.contains($0.offset) }.map { $0.element }
                // 清理不碰核心：只换列表，核心在跑继续用
                // 在用节点、停着继续停着；再清掉内存结果、
                // 按新列表剪掉已删节点的落盘缓存，最后刷新，
                // 否则旧失败结果还在、清理按钮永远不消失，
                // 看起来像没清理。
                CZFVPNManager.shared.replaceNodesWithoutCoreChange(kept)
                vpnNodes = CZFVPNManager.shared.nodeLinks
                vpnPingResults = [:]
                CZFVPNManager.savePingResults(vpnPingResults, nodes: vpnNodes)
                refreshVPNState()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(pendingClearFailedCount) 个测速不通的节点（在用节点与不支持的节点不会删），此操作不可恢复")
        }
        }
        // 被拒提示独立一行：原来它和一串按钮挤在同一行，
        // 长文字把按钮全挤没了；单独一行文字自然换行，
        // 按钮放下面一行，不再抢宽度。
        if vpnPingRejected && !vpnPinging {
            VStack(alignment: .leading, spacing: 4) {
                Text("上次测速被在跑的核心占用，结果没更新：先停核心再测更准，清理/排序按上次真测结果")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                // startVPNPing 已包办停核心→测速→重启，
                // 这里不用再手动 stop（原来两处停逻辑漂移）。
                Button("停核心重测") {
                    startVPNPing()
                }
                .buttonStyle(.borderless)
            }
        }
        Toggle(isOn: $vpnPrewarm) {
            HStack {
                // 只动这两处图标观感：底色统一降到 0.85 不透明度，
                // 橙/绿区分保留但不再刺眼；LCSettingsIcon 本体不动，
                // 其他行的图标不受影响。尺寸 30pt、圆角、15pt
                // semibold 白字仍走共用组件，不改布局。
                LCSettingsIcon(systemName: "flame.fill", color: .orange.opacity(0.85))
                Text("打开时预热节点核心")
            }
        }
        .onChange(of: vpnPrewarm) { _ in
            // 亲手拨一次预热开关：清掉测速后的预热抑制，
            // 之后预热照常工作；拨开关本身不动核心状态。
            CZFVPNManager.shared.notePrewarmSwitchToggled()
            refreshVPNState()
        }
        // 预热抑制可见：开关开着、测速后核心停着时，
        // 预热其实被压着不工作，以前界面上看不出，
        // 用户只会以为预热坏了；现在把状态说出来。
        if vpnPrewarmSuppressed && vpnPrewarm && !vpnCoreRunning {
            Text("测速后预热已暂停：拨一次预热开关可恢复")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        Toggle(isOn: $vpnAutoRotate) {
            HStack {
                LCSettingsIcon(systemName: "arrow.triangle.2.circlepath", color: .blue.opacity(0.85))
                Text("节点自动轮换")
            }
        }
        .onChange(of: vpnAutoRotate) { newValue in
            CZFVPNManager.setAutoRotate(newValue)
            refreshVPNState()
        }
        Toggle(isOn: $vpnHostProxy) {
            HStack {
                // 原来是 arrow.down.circle：带圈轮廓的符号在实心
                // 圆底上显得又小又淡，跟 flame.fill 的实心符号
                // 不是一套。换成无圈的 arrow.down，同样 15pt
                // 白字实心圆底，两行符号粗细、视觉分量一致。
                LCSettingsIcon(systemName: "arrow.down", color: .green.opacity(0.85))
                Text("源和下载也走内置节点")
            }
        }
            .onChange(of: vpnHostProxy) { newValue in
                CZFVPNManager.isHostProxyEnabled = newValue
                if newValue {
                    CZFVPNManager.shared.ensureRunningForHost()
                }
                refreshVPNState()
            }
        Picker(selection: $vpnAutoStopMinutes) {
            Text("5 分钟").tag(5)
            Text("10 分钟").tag(10)
            Text("30 分钟").tag(30)
            Text("永不").tag(-1)
        } label: {
            HStack {
                LCSettingsIcon(systemName: "timer", color: .red.opacity(0.85))
                Text("核心关闭后自动停")
            }
        }
    }
    func applySubscriptionLinks(_ links: [String]) {
        // 订阅自身含重复链接时先去重（保序），否则替换后出两行
        // 相同节点、单测按 firstIndex 永远只写第一行。
        var seen = Set<String>()
        let deduped = links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        CZFVPNManager.shared.replaceAllNodes(deduped)
        UserDefaults.standard.set(vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CZFVPNSubscriptionURL")
        // 订阅导入时直接剪落盘缓存：以前只清内存结果，
        // 被替换掉的节点还留在缓存里，下次存结果时才剪；
        // 先按新列表剪掉，再刷新、再从缓存恢复，恢复的
        // 只会是新列表里还留着的节点。
        CZFVPNManager.writePingCache(CZFVPNManager.readPingCache().filter { deduped.contains($0.key) })
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "订阅导入完成：共 \(deduped.count) 个节点（节点列表已替换为订阅内容）"
        successShow = true
    }

    /// 订阅合并导入：只追加订阅里没有的节点，保留手填
    /// 节点和活动节点（追加在末尾不移位，活动节点不变，
    /// 核心在跑也不重启）。没有新节点时列表不动。
    func mergeSubscriptionLinks(_ links: [String]) {
        // 先在订阅自身内去重（保序），再对原列表过滤：订阅自带
        // [A, A] 时只追加一个，否则两行相同节点、单测永远只写
        // 第一行，第二行永不更新。
        var seen = Set<String>()
        let cleaned = links
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let existing = CZFVPNManager.shared.nodeLinks
        let fresh = cleaned.filter { !existing.contains($0) }
        UserDefaults.standard.set(vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "CZFVPNSubscriptionURL")
        if fresh.isEmpty {
            successInfo = "订阅里没有新节点，列表未变"
            successShow = true
            return
        }
        // 走清理同款只换列表不碰核心：活动节点按内容找回，
        // 追加在末尾不移位，核心在跑也不重启。
        CZFVPNManager.shared.replaceNodesWithoutCoreChange(existing + fresh)
        CZFVPNManager.writePingCache(CZFVPNManager.readPingCache().filter { (existing + fresh).contains($0.key) })
        vpnPingResults = [:]
        refreshVPNState()
        successInfo = "合并导入完成：新增 \(fresh.count) 个节点，共 \(existing.count + fresh.count) 个"
        successShow = true
    }

    // 测延迟的实际动作（测延迟按钮与被拒时的
    // “停核心重测”共用，免得两处逻辑漂移）：
    // 进度按批回主线程，按钮显示“测速 3/10”/
    // “重试 2/5”，不再只有一句测速中。
    func startVPNPing() {
        // 测速期间保留旧结果不清空：原来一开测就清表，
        // 测速中界面是空的、要等整轮测完才回来；现在旧
        // 结果先留着（按钮进度另行显示“测速 3/10”），
        // 测完由 completion 整表替换，被拒也不覆写。
        // 用户 2026-11-03 定的“停止测速启动”：核心在跑时
        // 先停、测完重启原来那条；核心没在跑时直接测、
        // 测完不启动。停核心在测速标志立起来之前做，免得
        // 测速窗口内起停被 deferred 逻辑插队。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnPinging = true
        vpnPingRejected = false
        vpnPingDone = 0
        vpnPingTotal = vpnNodes.count
        vpnPingPhase = "测速"
        // 3.8.518（L43）：测速量的是调用时的节点列表；测速中途
        // 订阅替换确认框可能弹出并换掉整个列表（导入请求在测速
        // 前已发出、回包恰撞上测速窗口，确认框按钮没禁测速中），
        // 完成时按原下标合结果、按原下标自动切最快都会对错行——
        // 最坏切错节点重启核心，还把错延迟写进落盘缓存（按内容
        // 存，下次进页“切到最快”继续认错）。起跑时快照列表，
        // 部分结果与完成时先对快照。
        let pingNodes = CZFVPNManager.shared.nodeLinks
        CZFVPNManager.shared.pingAllNodes(onPartial: { partial in
            // 列表中途被换过就别按下标合部分结果（见起跑时快照）。
            guard CZFVPNManager.shared.nodeLinks == pingNodes else { return }
            // 3.8.519（L44）：合入部分结果时一并记快照——L43 只在批量
            // 完成/单测收尾/缓存恢复三处记，onPartial 这个第四写点漏了。
            // 首轮批量测速（快照还是空）中途列表被外边换掉时，已合入的
            // 旧下标部分结果既不被 completion 清（跳过合并分支），也不被
            // refreshVPNState 清（快照为空短路），会继续按旧下标显示在
            // 新列表上；记了快照，收尾 refresh 才能按快照对上清掉。
            vpnPingResultNodes = pingNodes
            // 通的先显示：只合并通的节点，不通的
            // 留空继续显示“测速中”，等最终结果；
            // 不在这里 save，最终结果才落盘。
            // 刚测通的节点同步清掉 stale 标记：别等整表
            // completion，测速中先显示的通节点一直灰色“·旧”
            // 是纯显示问题。
            for (i, r) in partial.enumerated() where r.success {
                vpnPingResults[i] = r
                vpnPingStaleIndices.remove(i)
            }
        }, onProgress: { done, total, phase in
            vpnPingDone = done
            vpnPingTotal = total
            vpnPingPhase = phase
        }) { results, rejected in
            // 3.8.518（L43）：列表中途被换过时下标结果已不对号——
            // 不覆写界面、不落盘、不自动切最快（旧结果已由替换方
            // 清掉，收尾 refresh 会按内容从缓存重建）；停过的核心
            // 照常重启。列表没变时与原来一模一样。
            let listUnchanged = CZFVPNManager.shared.nodeLinks == pingNodes
            if rejected {
                // 被拒那批全是失败，不是节点真不通：
                // 不覆写界面结果、不落盘，免得污染上次
                // 真测结果、清理/排序按假不通走；只出警告，
                // 清理/排序继续用上次真测结果。测速开始
                // 时已不再清空旧表，这里也不清空，直接
                // 保留旧结果即可，不用再靠缓存恢复。
                vpnPingRejected = true
            } else if listUnchanged {
                var map: [Int: CZFVPNManager.CZFNodePingResult] = [:]
                for (i, r) in results.enumerated() { map[i] = r }
                vpnPingResults = map
                vpnPingResultNodes = pingNodes
                vpnPingStaleIndices = []
                vpnSingleRejectedLinks = []
                vpnPingRejected = false
                CZFVPNManager.savePingResults(map, nodes: vpnNodes)
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            // R-3：测完自动切最快，与 App 页盾牌菜单同策略
            // （3.8.306）：只认刚测通的节点、已是最快就不切
            // （省一次重启）；切了就明示，不静默换节点。
            // 被拒那批全是失败，filter 自然找不到最快，不切。
            // 手动"切到最快"按钮还在（按缓存切，不用重测）。
            // 3.8.518（L43）：列表中途被换过时 results 的下标
            // 已不对号，不自动切（见本函数起跑时快照）。
            if listUnchanged, let best = results.enumerated().filter({ $0.element.success }).min(by: { $0.element.delay < $1.element.delay }),
               best.offset != CZFVPNManager.shared.activeNodeIndex,
               best.offset < CZFVPNManager.shared.nodeLinks.count {
                CZFVPNManager.shared.setActiveNode(at: best.offset)
                let name = CZFVPNManager.nodeDisplay(for: CZFVPNManager.shared.nodeLinks[best.offset]).name
                successInfo = "已切到最快节点：\(name)（\(best.element.delay)ms）"
                successShow = true
            }
            vpnPinging = false
            vpnPingDone = 0
            vpnPingTotal = 0
            refreshVPNState()
        }
    }

    // 单节点复测（长按行菜单）：只测这一条，不清整表。
    // 被拒时不覆写旧结果、只出警告；成功时只更新该节点
    // 的结果与缓存时间戳，其余节点结果不动。按链接内容
    // 对回下标，测速中列表变了也不错位。
    func startSinglePing(_ index: Int) {
        guard vpnNodes.indices.contains(index) else { return }
        // 滑动动作的 .disabled 不一定挡得住 List 行动作
        //（左滑删除已有同款教训、动作里另守一次），
        // 入口再守一次：测速中不叠加开第二轮单测。
        guard !vpnPinging && !vpnSinglePinging else { return }
        let link = vpnNodes[index]
        // 单测与批量同规则（251 只修了批量，行长按复测仍
        // 是老逻辑、核心在跑就拒，TUIC 行一直挂“核心占用”
        // 就是这么来的）：核心在跑先停、测完重启原来那条；
        // 没在跑直接测、测完不启动。停核心在测速标志立
        // 起来之前做，免得测速窗口内起停被 deferred 逻辑插队。
        let pingStoppedCore = CZFVPNManager.shared.stopCoreForPing()
        vpnSinglePingIndex = index
        vpnSinglePinging = true
        CZFVPNManager.shared.pingSingleNode(at: index) { result, rejected in
            vpnSinglePinging = false
            vpnSinglePingIndex = nil
            if rejected {
                vpnPingRejected = true
                vpnSingleRejectedLinks.insert(link)
            } else if let result {
                // 3.8.518（L43）：单测按链接内容对回下标；列表在外边
                // （设置导入/恢复）被换过时旧下标结果已不对号，先清
                // 掉再写这一条（批量测速同款，见 startVPNPing 的
                // pingNodes 快照）；链接已被删就没处可写，直接跳过。
                let currentLinks = CZFVPNManager.shared.nodeLinks
                if !vpnPingResultNodes.isEmpty && vpnPingResultNodes != currentLinks {
                    vpnPingResults = [:]
                    vpnPingStaleIndices = []
                    vpnPingResultNodes = []
                }
                if let currentIndex = currentLinks.firstIndex(of: link) {
                    vpnPingResults[currentIndex] = result
                    vpnPingStaleIndices.remove(currentIndex)
                    vpnSingleRejectedLinks.remove(link)
                    vpnPingResultNodes = currentLinks
                    // 只写该条缓存，别刷全表时间戳（见 savePingResult）。
                    CZFVPNManager.savePingResult(link: link, result: result, nodes: currentLinks)
                }
            }
            // 停过的核心测完重启原来那条（没停过就不启动）；
            // 放 refresh 之前，状态行直接显示重启后的状态。
            if pingStoppedCore {
                CZFVPNManager.shared.restartCoreAfterPing()
            }
            refreshVPNState()
        }
    }

    // 多选删除：按链接换算下标（删时现算，导入换列表不错位）；
    // 含在用节点走已有确认框，确认后退出多选；不含直接删。
    func deleteSelectedVPNNodeLinks() {
        guard !vpnPinging && !vpnSinglePinging else { return }
        let indices = vpnNodes.enumerated().compactMap { vpnSelectedNodeLinks.contains($0.element) ? $0.offset : nil }
        guard !indices.isEmpty else { return }
        if indices.contains(vpnActiveIndex) {
            pendingDeleteIndices = indices.sorted()
            showDeleteActiveConfirm = true
        } else {
            for i in indices.sorted(by: >) {
                CZFVPNManager.shared.removeNode(at: i)
            }
            vpnSelectedNodeLinks = []
            vpnNodeSelecting = false
            vpnPingResults = [:]
            refreshVPNState()
        }
    }

    // 订阅自动更新：开关开着、填了订阅地址、上次拉取超 24
    // 小时（或从没拉过）时才拉；走 mergeSubscriptionLinks
    // （只追加新节点，保留手填节点），成功/失败都走现有
    // successInfo/errorInfo 弹窗反馈；进 VPN 页检查一次。
    func autoUpdateSubscriptionIfNeeded() {
        guard vpnSubAutoUpdate else { return }
        let url = vpnSubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !vpnSubBusy else { return }
        let last = UserDefaults.standard.double(forKey: "CZFVPNSubAutoUpdateLast")
        if last > 0 && Date().timeIntervalSince1970 - last < 24 * 3600 { return }
        vpnSubBusy = true
        CZFVPNManager.fetchSubscriptionLinks(urlString: url) { result in
            DispatchQueue.main.async {
                vpnSubBusy = false
                switch result {
                case .success(let links):
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "CZFVPNSubAutoUpdateLast")
                    mergeSubscriptionLinks(links)
                case .failure(let error):
                    errorInfo = "订阅自动更新失败：\(error.localizedDescription)"
                    errorShow = true
                }
            }
        }
    }

    // O-7：读核心日志尾部（后台读、主线程显示；只读展示，
    // 不改文件；脱敏在 CZFVPNManager.coreLogTail 里做）。
    func loadCoreLog() {
        showCoreLog = true
        coreLogText = "正在读取…"
        DispatchQueue.global(qos: .userInitiated).async {
            let text = CZFVPNManager.coreLogTail()
            DispatchQueue.main.async { coreLogText = text }
        }
    }

    func refreshVPNState() {
        vpnNodes = CZFVPNManager.shared.nodeLinks
        // 3.8.518（L43）：内存测速结果是按下标记的，列表在外边
        // （设置导入/恢复）被换过时下标已不对号——清掉，下面的
        // restore 会按内容从缓存重建（行上不再显示错行的延迟，
        // “切到最快/清理不通/按延迟排序”也不会按错下标走）；
        // 列表没变、或测速进行中时不动（测速收尾自己对快照）。
        if !vpnPingResults.isEmpty && !vpnPinging && !vpnPingResultNodes.isEmpty && vpnPingResultNodes != vpnNodes {
            vpnPingResults = [:]
            vpnPingStaleIndices = []
            vpnPingResultNodes = []
        }
        // 核心占用标记按当前列表剪枝：删节点/订阅替换后孤儿标记
        // 自动掉，删掉重加同一条不会没测过就显示“核心占用”。
        // 链接集合标记，删/排/导都不错位，剪枝只删不在列表的。
        vpnSingleRejectedLinks = vpnSingleRejectedLinks.filter { vpnNodes.contains($0) }
        vpnActiveIndex = CZFVPNManager.shared.activeNodeIndex
        // 测速中不翻核心按钮：测速期间任何 onAppear/刷新
        // 都不该把按钮从停止翻成启动，核心状态以测速前为准，
        // 测完由 completion 一次性刷新。
        if !vpnPinging {
            vpnCoreRunning = CZFVPNManager.shared.isRunning
        }
        vpnStatusMessage = CZFVPNManager.shared.lastError
        vpnHostProxy = CZFVPNManager.isHostProxyEnabled
        vpnPrewarmSuppressed = CZFVPNManager.shared.isPrewarmSuppressedAfterPing
        // 内存里的测速结果被清空（增删/导入/排序都会清）时，
        // 从落盘缓存按节点内容重建，没测过的节点不显示
        if vpnPingResults.isEmpty && !vpnPinging {
            let restored = CZFVPNManager.restorePingResults(nodes: vpnNodes)
            if !restored.results.isEmpty {
                vpnPingResults = restored.results
                vpnPingStaleIndices = restored.stale
                vpnPingResultNodes = vpnNodes
            }
        }
    }

    // R-3：测速结果持久化已抽到 CZFVPNManager（共用缓存，
    // 与 App 页同一份 CZFVPNPingCache，同一编解码）；本页
    // 只留调用点，私有读写/编解码/恢复方法已删。

}

// 节点行：原 LCSettingsView.swift 里的 CZFVPNNodeLabel，整段搬过来。
private struct CZFVPNNodeLabel: View {
    let link: String
    let ping: CZFVPNManager.CZFNodePingResult?
    let isActive: Bool
    let coreRunning: Bool
    let pinging: Bool
    let isSinglePingTarget: Bool
    let isRejected: Bool
    let isStale: Bool

    var body: some View {
        // O-18：nodeDisplay 每行只算一次——原来 name/detail 各调
        // 一次（两次解析链接、读别名）；算一次、两次用同一结果。
        let display = CZFVPNManager.nodeDisplay(for: link)
        HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(display.detail)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                Spacer()
                // 延迟测试结果（点下面的「测延迟」
                // 后显示）：绿 <300ms、橙 <800ms、
                // 红 ≥800ms；失败显示 超时/不通。
                // 例外：在用节点且核心在跑时，测速失败
                // 不显示不通——核心在跑且实际能上网
                // 是比一次测速样本更强的证据，显示
                // 不通只会逼用户误换 IP（养号大忌）
                if let ping, !ping.success, isActive, coreRunning {
                    Text("在用")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if (pinging || isSinglePingTarget) && ping == nil {
                    Text("测速中")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if isSinglePingTarget {
                    Text("测速中")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else if isRejected {
                    // 单测被拒：只剩测速中途核心又被起起来的竞
                    // 态（单测与批量一样先停核心再测，见
                    // startSinglePing）；旧值原样保留，行上直接
                    // 写“核心占用”，别让用户对着不变的数字猜。
                    Text("核心占用")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if ping == nil, !CZFVPNManager.isSupportedNodeScheme(CZFVPNManager.nodeScheme(for: link)) {
                    // 未测到的不支持节点：按转换器清单静态分级，
                    // 直接标“不支持”（橙色，与实测失败的红色区分），
                    // 不等人测完才知道它跑不了。
                    Text("不支持")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let ping {
                    // 超 24 小时的缓存结果：灰色加“·旧”，
                    // 别按新鲜延迟的颜色误导切节点。
                    if ping.success {
                        Text(isStale ? "\(ping.delay)ms·旧" : "\(ping.delay)ms")
                            .font(.caption)
                            .foregroundStyle(isStale ? .gray : (ping.delay < 300 ? .green : (ping.delay < 800 ? .orange : .red)))
                    } else {
                        // 转换失败与网络失败分开显示：转换器拒收
                        // 是协议不支持，不是网络不通。
                        Text((ping.conversionFailed ? "不支持" : (ping.delay == 11000 ? "超时" : "不通")) + (isStale ? "·旧" : ""))
                            .font(.caption)
                            .foregroundStyle(isStale ? .gray : .red)
                    }
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
        }
    }
}
