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
            completionHandler([.banner, .list, .sound])
        }
    }
}

@objc class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? ) -> Bool {
        application.shortcutItems = nil
        UserDefaults.standard.removeObject(forKey: "LCNeedToAcquireJIT")
        // 通知代理必须在启动时就设好、且由 shared 强持有
        // （center 的 delegate 是弱引用，临时对象会被释放）。
        UNUserNotificationCenter.current().delegate = CZFNotificationDelegate.shared
        
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
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
        newOptions!._setRequestFullscreen(UIScreen.main.bounds == self.keyWindow!.bounds)
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

