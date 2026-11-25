//
//  MultitaskManager.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

enum MultitaskMode : Int {
    case virtualWindow = 0
    case nativeWindow = 1
}

@objc class MultitaskManager : NSObject {
    static private var usingMultitaskContainers : [String] = []
    // 3.8.571（L332-1）：这张表读写不在同一线程——读方在 runApp 内
    // （M:1039/:1080 isMultitasking、M:1731 isUsing），LCAppModel
    // 不是 @MainActor、runApp :901 亦然，调用方是裸 Task；写方注
    // 册在扩展完成回调里（AppSceneViewController.m:105，回调不在
    // 主线程——紧接着的 setUpAppPresenter 还要 dispatch 回主线程）、
    // 注销在主线程（:363 包在 dispatch main 里）。无锁 Swift 数组
    // 一边 append/removeAll 一边 contains，撞上重分配就是
    // use-after-free 闪退（先后起两个 App、一边起一边退时最易
    // 撞上）。一把 NSLock 护住四处访问，单次操作内持锁、不嵌套。
    static private let usingMultitaskContainersLock = NSLock()
    
    @objc class func registerMultitaskContainer(container: String) {
        usingMultitaskContainersLock.lock()
        defer { usingMultitaskContainersLock.unlock() }
        usingMultitaskContainers.append(container)
    }
    
    @objc class func unregisterMultitaskContainer(container: String) {
        usingMultitaskContainersLock.lock()
        defer { usingMultitaskContainersLock.unlock() }
        usingMultitaskContainers.removeAll(where: { c in
            return c == container
        })
    }
    
    @objc class func isUsing(container: String) -> Bool {
        usingMultitaskContainersLock.lock()
        defer { usingMultitaskContainersLock.unlock() }
        return usingMultitaskContainers.contains { c in
            return c == container
        }
    }
    
    @objc class func isMultitasking() -> Bool {
        usingMultitaskContainersLock.lock()
        defer { usingMultitaskContainersLock.unlock() }
        return usingMultitaskContainers.count > 0
    }
}
