//
//  LCAppPreferenceView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/10.
//
import SwiftUI

protocol LCAppPreferencesDelegate {
    func get(key: String) -> AnyHashable?
    func set(key: String, val: AnyHashable?)
    func localize(_ key: String) -> String
}


struct PSTextField: View {
    let title : String
    let key : String
    let defaultValue : String?
    let delegate : LCAppPreferencesDelegate
    @State var val : String
    
    init(title: String, key: String, defaultValue: String?, delegate: LCAppPreferencesDelegate) {
        self.title = title
        self.key = key
        self.defaultValue = defaultValue
        self.delegate = delegate
        self._val = State(initialValue: delegate.get(key: key) as? String ?? defaultValue ?? "")
    }
    
    var body: some View {
        HStack {
            Text(delegate.localize(title))
            Spacer()
            TextField("", text: $val)
                .onSubmit {
                    delegate.set(key: key, val: val)
                }
                .multilineTextAlignment(.trailing)
        }
        // 3.8.900（L568-21）：只在 onSubmit 存——用户改完直接点
        // 返回（不按键盘回车）就丢了本次输入，下次进页还是旧值，
        // 静默丢设置（LCContainerView 的容器名/IDFV/代理三处同款
        // 已在 onDisappear 补存，这里是漏的一处）。离开页面时再
        // 存一次，与提交同值、幂等；进子页面时行也会消失，存的
        // 是同一份值，无害。
        .onDisappear {
            delegate.set(key: key, val: val)
        }
    }
    
}

struct PSTitleValue: View {
    let title : String
    let key : String
    let defaultValue : AnyHashable
    let values : [AnyHashable]?
    let titles : [String]?
    let delegate : LCAppPreferencesDelegate
    
    init(title: String, key: String, defaultValue: AnyHashable, values: [AnyHashable]?, titles: [String]?, delegate: LCAppPreferencesDelegate) {
        self.title = title
        self.key = key
        self.defaultValue = defaultValue
        self.values = values
        self.titles = titles
        self.delegate = delegate
    }

    // 3.8.651（B2）：显示值是 computed——原来是 init 里算一次的
    // let，兄弟行/子页改了同一 key 后本行仍显示冻结的旧值；
    // 每次 body 求值现读 delegate.get 再映射 titles（映射逻辑
    // 与原 init 一字相同：无 values/titles 表时读原值，realValue
    // 为空时读默认值对应的标题）。
    var displayValue: String {
        let realValue = delegate.get(key: key)
        var defaultValueText = defaultValue as? String ?? ""
        let realValueText = realValue as? String ?? defaultValueText
        guard let values, let titles, values.count == titles.count else {
            return realValueText
        }

        for i in 0..<values.count {
            if values[i] == defaultValue {
                defaultValueText = titles[i]
                break
            }
        }

        guard let realValue else {
            return defaultValueText
        }

        for i in 0..<values.count {
            if values[i] == realValue {
                return titles[i]
            }
        }
        return realValueText
    }
    
    var body: some View {
        HStack {
            Text(delegate.localize(title))
            Spacer()
            Text(delegate.localize(displayValue))
                .foregroundStyle(.secondary)
        }

    }
}

struct PSMultiValue: View {
    let title : String
    let key : String
    let defaultValue : AnyHashable
    let values : [AnyHashable]
    let titles : [String]
    let delegate : LCAppPreferencesDelegate
    @State var realValue : AnyHashable
    
    init(title: String, key: String, defaultValue: AnyHashable, values: [AnyHashable], titles: [String], delegate: LCAppPreferencesDelegate) {
        self.title = title
        self.key = key
        self.defaultValue = defaultValue
        self.values = values
        self.titles = titles
        self.delegate = delegate
        self._realValue = State(initialValue: delegate.get(key: key) ?? defaultValue)

    }
    
    var body: some View {
        Picker(delegate.localize(title), selection: $realValue) {
            ForEach(values.indices, id:\.self) { i in
                Text(delegate.localize(titles[i])).tag(values[i])
            }
        }
        .onChange(of: realValue) { newValue in
            delegate.set(key: key, val: realValue)
        }
    }
}

struct PSToggleSwitch: View {
    let title : String
    let key : String
    let defaultValue : AnyHashable
    let trueValue : AnyHashable
    let falseValue : AnyHashable
    let delegate : LCAppPreferencesDelegate
    @State var realValue : Bool = false
    
    init(title: String, key: String, defaultValue: AnyHashable, trueValue: AnyHashable?, falseValue: AnyHashable?, delegate: LCAppPreferencesDelegate) {
        self.title = title
        self.key = key
        self.defaultValue = defaultValue
        self.delegate = delegate
        self.trueValue = trueValue ?? true as AnyHashable
        self.falseValue = falseValue ?? false as AnyHashable
        let currentValue = delegate.get(key: key) ?? defaultValue
        if currentValue == self.trueValue {
            _realValue = State(initialValue: true)
        }
    }
    
    var body: some View {
        Toggle(delegate.localize(title), isOn: $realValue)
            .onChange(of: realValue) { newValue in
                delegate.set(key: key, val: newValue ? trueValue : falseValue)
            }
    }
}

struct PSSlider : View {
    let key : String
    let defaultValue : Float
    let minimumValue : Float
    let maximumValue : Float
    let delegate : LCAppPreferencesDelegate
    @State var realValue : Float
    
    init(key: String, defaultValue: Float, minimumValue: Float, maximumValue: Float, delegate: LCAppPreferencesDelegate) {
        self.key = key
        self.defaultValue = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.delegate = delegate
        let currentValue = delegate.get(key: key) as? Float ?? defaultValue
        self._realValue = State(initialValue: currentValue)
    }
    
    var body: some View {
        Slider(value: $realValue, in:minimumValue...maximumValue, onEditingChanged: { c in
            if !c {
                delegate.set(key: key, val: realValue)
            }
        })
        
    }
}

struct PSChildPane: View {
    let title : String
    
    let rootPlistUrl : URL
    let bundleId : String
    let settingsBundle : Bundle
    let containerURL : URL
    
    let delegate : LCAppPreferencesDelegate
    
    var body: some View {
        NavigationLink {
            AppPreferencePageView(preferencePlistURL: rootPlistUrl, bundleId: bundleId, containerURL: containerURL, settingsBundle: settingsBundle)
                .navigationTitle(delegate.localize(title))
        } label: {
            Text(delegate.localize(title))
        }
    }
}

struct PSGroup: View {
    // 3.8.651（B2）：children 改 plain let——原来是 @State，初值只
    // 生效一次，父页重建行表后组内行还是首建那批（标题行照样不刷新）；
    // 组内行从不被改写（只在 body 里读），plain let 即够用，重建即透传。
    let children : [AnyView]
    let title : String
    let footerText : String
    let delegate : LCAppPreferencesDelegate
    
    var body: some View {
        Section {
            ForEach(children.indices, id: \.self) { i in
                children[i]
            }
        } header: {
            Text(delegate.localize(title))
        } footer: {
            Text(delegate.localize(footerText))
        }
    }
    
}

struct AppPreferencePageView : View {
    let preferencePlistURL : URL
    // 3.8.647（B3 修法）：存一份 containerURL——原来 init 只拿它建
    // UserDefaults、不存，body 里 onAppear/onDisappear 引它报
    // cannot find 'containerURL' in scope（首推唯三红字）；存量与
    // preferencePlistURL 同款（init 里赋值）。
    let containerURL : URL

    @State var children : [AnyView] = []
    @State var errorInfo : String?

    init(preferencePlistURL : URL, bundleId : String, containerURL : URL, settingsBundle: Bundle) {
        // 3.8.647（B3）：进页即拿 scope——子页不走 getContainerURL，
        // 这里的拿覆盖子页首读（读在 body 求值时、onAppear 之前）；
        // 重复拿是空操作，离开时由 AppPreferenceView.onDisappear 放。
        LCAppSettingsView.czfAcquirePreferenceAccess(for: containerURL)
        self.containerURL = containerURL
        self.preferencePlistURL = preferencePlistURL
        let built = Self.czfBuildChildren(preferencePlistURL: preferencePlistURL, bundleId: bundleId, containerURL: containerURL, settingsBundle: settingsBundle)
        errorInfo = built.error
        self._children = State(initialValue: built.children)
    }

    /// 3.8.651（B2）：建行表（plist → 行 + 读失败文案）——init 与
    /// onAppear/onReceive 共用：原来只在 init 建一次、存进 @State，
    /// 之后 body 再求值也不重建；兄弟行/子页改了 key 后标题行一直
    /// 是首建那批。每次建都新起一个 AppPreferenceModel（同一
    /// UserDefaults 套件），行内 @State（文本框/多选/开关）按
    /// 下标+类型复用，不丢正在输的内容。
    private static func czfBuildChildren(preferencePlistURL: URL, bundleId: String, containerURL: URL, settingsBundle: Bundle) -> (children: [AnyView], error: String?) {
        var children : [AnyView] = []
        guard let dict = NSMutableDictionary(contentsOf: preferencePlistURL) else {
            return ([], "Failed to load preference.")
        }
        guard let items = dict["PreferenceSpecifiers"] as? [[String:Any]] else {
            return ([], "Failed to load preference.")
        }
        let suiteName = dict["ApplicationGroupContainerIdentifier"] as? String ?? bundleId
        let stringTable = dict["StringsTable"] as? String ?? nil
        
        let userDefaults = UserDefaults()._init(withSuiteName: suiteName, container: containerURL)!
        let delegate = AppPreferenceModel(settingsBundle: settingsBundle, userDefaults:userDefaults, table: stringTable)
        
        var currGroup : [String:Any]? = nil
        var currGroupChildren : [AnyView] = []
        for item in items {
            guard let type = item["Type"] as? String else {
                continue
            }
            var currView : (any View)?
            if type == "PSTitleValueSpecifier" {
                guard let title = item["Title"] as? String, let key = item["Key"] as? String, let defaultValue = item["DefaultValue"] as? AnyHashable else {
                    continue
                }
                currView = PSTitleValue(title: title, key: key, defaultValue: defaultValue, values: item["Values"] as? [AnyHashable], titles: item["Titles"] as? [String], delegate: delegate)
            } else if type == "PSTextFieldSpecifier" {
                guard let title = item["Title"] as? String, let key = item["Key"] as? String else {
                    continue
                }
                currView = PSTextField(title: title, key: key, defaultValue: item["DefaultValue"] as? String, delegate: delegate)
            } else if type == "PSMultiValueSpecifier" || type == "PSRadioGroupSpecifier" {
                guard let title = item["Title"] as? String, let key = item["Key"] as? String, let defaultValue = item["DefaultValue"] as? AnyHashable, let values = item["Values"] as? [AnyHashable], let titles = item["Titles"] as? [String] else {
                    continue
                }
                currView = PSMultiValue(title: title, key: key, defaultValue: defaultValue, values: values, titles: titles, delegate: delegate)
            } else if type == "PSToggleSwitchSpecifier" {
                guard let title = item["Title"] as? String, let key = item["Key"] as? String, let defaultValue = item["DefaultValue"] as? AnyHashable else {
                    continue
                }
                currView = PSToggleSwitch(title: title, key: key, defaultValue: defaultValue, trueValue: item["TrueValue"] as? AnyHashable, falseValue: item["FalseValue"] as? AnyHashable, delegate: delegate)
            } else if type == "PSSliderSpecifier" {
                guard let key = item["Key"] as? String, let defaultValue = item["DefaultValue"] as? Float, let minimumValue = item["MinimumValue"] as? Float, let maximumValue =  item["MaximumValue"] as? Float else {
                    continue
                }
                currView = PSSlider(key: key, defaultValue: defaultValue, minimumValue: minimumValue, maximumValue: maximumValue, delegate: delegate)
            } else if type == "PSChildPaneSpecifier"{
                guard let title = item["Title"] as? String, let file = item["File"] as? String else {
                    continue
                }
                let fileURL = preferencePlistURL.deletingLastPathComponent().appendingPathComponent(file).appendingPathExtension("plist")
                currView = PSChildPane(title: title, rootPlistUrl: fileURL, bundleId: bundleId, settingsBundle: settingsBundle, containerURL: containerURL, delegate: delegate)
                
            } else if type == "PSGroupSpecifier" {

                if let currGroup {
                    currView = PSGroup(children: currGroupChildren, title: currGroup["Title"] as? String ?? "", footerText: currGroup["FooterText"] as? String ?? "", delegate: delegate)
                    currGroupChildren = []
                }
                currGroup = item
            }
            guard let currView else {
                continue
            }
            if currGroup == nil || type == "PSGroupSpecifier" {
                    children.append(AnyView(currView))
            } else {
                currGroupChildren.append(AnyView(currView))
            }
        }
        if let currGroup {
            let currView = PSGroup(children: currGroupChildren, title: currGroup["Title"] as? String ?? "", footerText: currGroup["FooterText"] as? String ?? "", delegate: delegate)
            children.append(AnyView(currView))
        }
        return (children, nil)
    }
    
    var body: some View {
            Form {
                // init 里 plist 读失败会置 errorInfo，但原来 body 里
                // 从没显示它——设置页只剩一张空白表单，用户不知道
                // 是没读到还是本来就没项。读失败时把错亮出来。
                if let errorInfo {
                    Text(errorInfo)
                        .foregroundStyle(.red)
                }
                ForEach(children.indices, id: \.self) { i in
                    children[i]
                }
            }
            // 3.8.647（B3）：偏好页出现/消失记可见数——进子页时父页
            // 消失，计数挡住 AppPreferenceView.onDisappear 那次
            // 释放（子页还在读写同一容器的偏好）；出现时再拿一次
            // scope（返回时若已放掉就地续上，重复拿是空操作）。
            .onAppear {
                LCAppSettingsView.czfAcquirePreferenceAccess(for: containerURL)
                LCAppSettingsView.czfPreferencePageAppeared(for: containerURL)
                // 3.8.651（B2）：回页重建行表——进子页改完同一 key
                // 回来，标题行才跟上新值（只靠 computed 值不够，
                // children 是 @State、body 不重建行实例）。
                children = Self.czfBuildChildren(preferencePlistURL: preferencePlistURL, bundleId: bundleId, containerURL: containerURL, settingsBundle: settingsBundle).children
            }
            // 3.8.651（B2）：同页联动——兄弟行改了 key 就重建行表
            //（标题行现读新值；多选/开关自己的 @State 按下标+类型
            // 复用，改它的那行不会丢状态、不会触发 onChange 回环）。
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CZFPreferenceValueChanged"))) { _ in
                children = Self.czfBuildChildren(preferencePlistURL: preferencePlistURL, bundleId: bundleId, containerURL: containerURL, settingsBundle: settingsBundle).children
            }
            .onDisappear {
                LCAppSettingsView.czfPreferencePageDisappeared(for: containerURL)
            }

    }
}

class AppPreferenceModel: LCAppPreferencesDelegate {
    let settingsBundle : Bundle
    let userDefaults : UserDefaults
    let table : String?
    private static var _enBundle : Bundle?
    private static var _enBundleFound = false
    private var enBundle : Bundle? {
        if AppPreferenceModel._enBundleFound {
            return AppPreferenceModel._enBundle;
        }
        let language = "en"
        if let path = settingsBundle.path(forResource:language, ofType: "lproj") {
            let bundle = Bundle(path: path)
            AppPreferenceModel._enBundle = bundle
        }
        AppPreferenceModel._enBundleFound = true
        return AppPreferenceModel._enBundle
    }
    
    init(settingsBundle: Bundle, userDefaults: UserDefaults, table: String?) {
        self.settingsBundle = settingsBundle
        self.userDefaults = userDefaults
        self.table = table
    }
    
    func get(key: String) -> AnyHashable? {
        return self.userDefaults.object(forKey: key) as? AnyHashable ?? nil
    }
    
    func set(key: String, val: AnyHashable?) {
        self.userDefaults.set(val, forKey: key)
        // 3.8.651（B2）：同页联动——兄弟行（标题值）不订阅任何
        // 状态，set 完不通知就没人重渲染；发一次通知，偏好页
        // 接住重建行表（标题行现读新值）。子页的 set 也会发，
        // 父页接住重建的是屏下行表，无害、回页时本来也要重建。
        NotificationCenter.default.post(name: Notification.Name("CZFPreferenceValueChanged"), object: nil)
    }
    
    func localize(_ key: String) -> String {
        if let table {
            let message = NSLocalizedString(key, tableName: table, bundle: settingsBundle, comment: "")
            if message != key {
                return message
            }
            if let forcedString = enBundle?.localizedString(forKey: key, value: nil, table: table){
                return forcedString
            } else {
                return key
            }
        } else {
            return key
        }
        
    }
    
}

struct AppPreferenceView: View {
    let rootPlistUrl : URL
    let bundleId : String
    let settingsBundle : Bundle
    let containerURL : URL
    
    init(bundleId: String, settingsBundle: Bundle, containerURL: URL) {
        self.bundleId = bundleId
        self.settingsBundle = settingsBundle
        self.containerURL = containerURL
        self.rootPlistUrl = settingsBundle.bundleURL.appendingPathComponent("Root.plist")

    }

    var body: some View {
        AppPreferencePageView(preferencePlistURL: rootPlistUrl, bundleId: bundleId, containerURL : containerURL, settingsBundle: settingsBundle)
            // 3.8.647（B3）：偏好页真正离开时放 scope——进子页时本页
            // 也消失，子页的可见计数挡住那次释放（见 LCAppSettingsView
            // czfReleasePreferenceAccess）；计数归零才放，不再永久持有。
            .onDisappear {
                LCAppSettingsView.czfReleasePreferenceAccess(for: containerURL)
            }
    }
}
