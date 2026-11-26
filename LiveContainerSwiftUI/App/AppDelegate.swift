import UIKit
import SwiftUI
import Intents
import UserNotifications

/// 宿主通知代理（CZF，2026-10-29 通知恢复）：
/// 游客 App 和宿主跑在同一个进程里，游客的本地通知走的就
/// 是宿主这个通知中心。以前宿主从没设过 delegate，iOS 的
/// 默认规则是：App 在前台时通知不弹横幅、不响铃，只静默进
/// 通知中心——游客最小化挂在后台时消息来了，App 自己只震
/// 一下，用户在宿主前台却看不到任何横幅，以为“啥通知都没”。
/// 设了这个代理后，前台也弹横幅、响铃，通知才算真的恢复。
/// 例外：批量安装完成那条（CZFBatchInstall 开头）保持原来
/// 的静默行为，只进通知中心不弹横幅，靠顶部小条和汇总弹窗。
final class CZFNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CZFNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.identifier.hasPrefix("CZFBatchInstall") {
            completionHandler([])
        } else {
            // 3.8.666（F-3）：CZFBackupDone（备份完成）故意走这条默认
            // 分支——前台也弹横幅 + 响铃；备份是用户切走后才关心的
            // 完成信号，与批量安装的静默策略不同。
            completionHandler([.banner, .list, .sound])
        }
    }
}

@objc class AppDelegate: UIResponder, UIApplicationDelegate {

    private var willTerminateObserver: NSObjectProtocol?

    // 3.8.666（B-1）：后台下载会话接管——进程被杀后系统以后台事件
    // 唤起 App 时，handleEventsForBackgroundURLSession 用事件给的
    // identifier 重建会话；session 与 delegate 由本字典强持有，
    // 事件交完（urlSessionDidFinishEvents）后释放。identifier 集合
    // 对外可见：LCTabView 启动自动续跳过接管中的记录，不再建同
    // identifier 会话抢事件。读写都在主线程（接管回调里那处用
    // DispatchQueue.main.async 回主线程再清）。
    static var czfBackgroundTakeoverIdentifiers: Set<String> = []
    private var czfBackgroundSessions: [String: (session: URLSession, delegate: CZFBackgroundDownloadDelegate)] = [:]

    // 3.8.666（B-1）：后台下载会话接管——进程被杀/被系统回收后，
    // 后台下载任务在守护进程里继续跑，跑完/失败时系统唤起 App
    // 交付事件；用事件给的 identifier 重建会话（必须是 background
    // 配置——hostDownloadConfiguration 在代理开着时返回 .default
    // 前台配置，identifier 不生效，接管不到任务），事件交付完
    // delegate 调 completionHandler。delegate 的收尾（搬文件/
    // 留续传数据）只走磁盘记录，见 CZFBackgroundDownloadDelegate。
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        let delegate = CZFBackgroundDownloadDelegate(identifier: identifier, completionHandler: completionHandler)
        delegate.czfOnFinished = { [weak self] id in
            DispatchQueue.main.async {
                self?.czfBackgroundSessions.removeValue(forKey: id)
                Self.czfBackgroundTakeoverIdentifiers.remove(id)
            }
        }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        czfBackgroundSessions[identifier] = (session, delegate)
        Self.czfBackgroundTakeoverIdentifiers.insert(identifier)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        // 通知代理必须在启动时就设好、且由 shared 强持有
        // （center 的 delegate 是弱引用，临时对象会被释放）。
        UNUserNotificationCenter.current().delegate = CZFNotificationDelegate.shared
        
        // 3.8.498（L17）：block 观察者返的 token 必须留住（见
        // CZFHostKeepAlive.swift 同款注释），丢掉就当场注销。
        willTerminateObserver = NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Fix launching app if user opens JIT waiting dialog and kills the app. Won't trigger normally.
            if DataManager.shared.model.isJITModalOpen && !UserDefaults.standard.bool(forKey: "LCKeepSelectedWhenQuit"){
                UserDefaults.standard.removeObject(forKey: "selected")
                UserDefaults.standard.removeObject(forKey: "selectedContainer")
            }
        }
        
        // allow new scene pop up as a new fullscreen window
        method_exchangeImplementations(
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.requestSceneSessionActivation(_ :userActivity:options:errorHandler:)))!,
            class_getInstanceMethod(UIApplication.self, #selector(UIApplication.hook_requestSceneSessionActivation(_:userActivity:options:errorHandler:)))!)

        // remove symbol caches if user upgraded iOS
        if let lastIOSBuildVersion = LCUtils.appGroupUserDefault.string(forKey: "LCLastIOSBuildVersion"),
           let currentVersion = UIDevice.current.buildVersion,
           lastIOSBuildVersion == currentVersion {
            
        } else {
            LCUtils.appGroupUserDefault.removeObject(forKey: "symbolOffsetCache")
            LCUtils.appGroupUserDefault.setValue(UIDevice.current.buildVersion, forKey: "LCLastIOSBuildVersion")
        }
        
        // 部署快捷栏边缘手势插件到全局 Tweaks 并签名（赶在任何游客 App 启动前）
        if #available(iOS 16.0, *) {
            MultitaskDockManager.deployDockGestureTweak()
        }

        // 部署钥匙串桥插件（游客进程内导出/写回钥匙串）到全局
        // Tweaks 并签名，同样赶在任何游客 App 启动前
        LCDataManagementView.deployKeychainBridgeTweak()

        // 宿主侧保活：装后台/前台观察者；真正播放只在切后台且有游客时
        CZFHostKeepAlive.shared.install()

        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
    
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is ViewAppIntent: return ViewAppIntentHandler()
        default:
            return nil
        }
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject { // Make SceneDelegate conform ObservableObject
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        self.window = (scene as? UIWindowScene)?.keyWindow
    }

    // 3.8.346：window 只在 willConnectTo 取一次 keyWindow、永不
    // 刷新——连接时 keyWindow 可为 nil（下方
    // hook_requestSceneSessionActivation 里注释自己承认），
    // 之后弹框锚它就静默退全局查找、框可能弹错
    // 窗。场景激活时刷新：sceneDidBecomeActive 时本场景已是
    // 前台、keyWindow 已落定；nil 时退回 scene.windows 里的
    // keyWindow/首个可见窗。SwiftUI 自动把 SceneDelegate 作
    // @EnvironmentObject 注进本场景各视图，刷新后各处读到新值。
    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        if let keyWindow = windowScene.keyWindow {
            self.window = keyWindow
        } else if let visibleWindow = windowScene.windows.first(where: { !$0.isHidden }) {
            self.window = visibleWindow
        }
    }
}


@objc extension UIApplication {
    
    func hook_requestSceneSessionActivation(
        _ sceneSession: UISceneSession?,
        userActivity: NSUserActivity?,
        options: UIScene.ActivationRequestOptions?,
        errorHandler: ((any Error) -> Void)? = nil
    ) {
        var newOptions = options
        if newOptions == nil {
            newOptions = UIScene.ActivationRequestOptions()
        }
        // keyWindow 可为 nil（后台发起的激活请求到来时还没
        // 有 key window），强解包会在系统钩子内闪退；取不到
        // 按非全屏处理，钩子本身的转发逻辑不动。
        let isFullscreen: Bool
        if let keyWindow = self.keyWindow {
            isFullscreen = UIScreen.main.bounds == keyWindow.bounds
        } else {
            isFullscreen = false
        }
        newOptions!._setRequestFullscreen(isFullscreen)
        self.hook_requestSceneSessionActivation(sceneSession, userActivity: userActivity, options: newOptions, errorHandler: errorHandler)
    }
    
}

public class ViewAppIntentHandler: NSObject, ViewAppIntentHandling
{
    public func provideAppOptionsCollection(for intent: ViewAppIntent, with completion: @escaping (INObjectCollection<App>?, Error?) -> Void)
    {
        completion(INObjectCollection(items:[]), nil)
    }
}

