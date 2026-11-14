//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // 壁纸顶栏黑底（3.8.457）：App 页顶栏与源页同款
        // czfSolidToolbarBackground（.toolbarBackground 实底），
        // 但真机上 App 页顶仍透出壁纸变黑——SwiftUI 的
        // .toolbarBackground 在本页没生效（两页代码逐行同款，
        // 根因未定位）。改走 UIKit 外观代理强制不透明导航栏，
        // 与源页白顶一致；只设背景色不改别的。放 init 最前面，
        // 导航栏创建前就生效。
        let czfNavAppearance = UINavigationBarAppearance()
        czfNavAppearance.configureWithOpaqueBackground()
        czfNavAppearance.backgroundColor = .systemBackground
        UINavigationBar.appearance().standardAppearance = czfNavAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = czfNavAppearance
        UINavigationBar.appearance().compactAppearance = czfNavAppearance

        // 保活启动同步：重装后开关默认开，第一次启动即把
        // dylib 部署进全局 Tweaks，不等用户打开设置页
        LCSettingsView.syncKeepAliveAtLaunch()

        // P2（3.8.279）：冷启动扫描移出主线程——原来 init 里同步
        // 枚举 bundle 目录、逐个读两个 plist 建 LCAppInfo/Model，
        // 几十次解析堵在首帧之前。改后台扫：先出首帧，扫完回主
        // 线程一次赋值；排序管理器订阅了 model.$apps，赋值即重排，
        // 列表随后上；定时备份/预热那时读到空只会跳过、不记日期。
        // LCAppInfo/LCAppModel 的 init 只读 plist 与自身属性，无
        // UIKit，后台建安全；@Published 赋值必须回主线程。
        Task.detached(priority: .userInitiated) {
            let scanned = Self.scanAppLists()
            await MainActor.run {
                let model = DataManager.shared.model
                model.apps = scanned.apps
                model.arm32EmuApps = scanned.arm32EmuApps
                model.hiddenApps = scanned.hiddenApps
                model.appDataFolderNames = scanned.appDataFolderNames
                model.tweakFolderNames = scanned.tweakFolderNames
                if let schemes = scanned.urlSchemes {
                    UserDefaults.lcShared().set(Array(schemes), forKey: "LCGuestURLSchemes")
                }
            }
        }
    }

    /// 冷启动扫描（P2：后台跑）：原 init 里的同一段，逻辑一字
    /// 未动，只挪出来。返回五份清单 + URL schemes（非主 App 时为 nil）。
    private static func scanAppLists() -> (apps: [LCAppModel], arm32EmuApps: [LCAppModel], hiddenApps: [LCAppModel], appDataFolderNames: [String], tweakFolderNames: [String], urlSchemes: Set<String>?) {
        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []
        var tempURLSchemes: Set<String>? = DataManager.shared.model.multiLCStatus != 2 ? Set() : nil

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs {
                if !appDir.hasSuffix(".app") {
                    continue
                }
                let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)")!
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                let model = LCAppModel(appInfo: newApp)
                if newApp.isHidden {
                    tempHiddenApps.append(model)
                } else {
                    tempApps.append(model)
                }
                // 隐藏 App 的 URL schemes 也要进集合（原来只在 else
                // 里 formUnion，冷启动会丢掉隐藏 App 的 schemes，
                // 客 App 里点隐藏 App 链接回不了宿主）。
                // 坏包兜底：CFBundleURLSchemes 里混进非字符串时 as!
                // 会在冷启动扫描里直接闪退，且每次启动都崩、用户
                // 删不掉坏包；as? 失败只跳过它的 schemes。
                tempURLSchemes?.formUnion(newApp.urlSchemes() as? [String] ?? [])
                if newApp.is32bitEmulator {
                    tempArm32EmuApps.append(model)
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared {
                    if !appDir.hasSuffix(".app") {
                        continue
                    }
                    let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)")!
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    let model = LCAppModel(appInfo: newApp)
                    if newApp.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(model)
                    }
                    // 隐藏 App 的 URL schemes 也要进集合（同上）。
                    // 坏包兜底：同上，as? 失败只跳过它的 schemes。
                    tempURLSchemes?.formUnion(newApp.urlSchemes() as? [String] ?? [])
                    if newApp.is32bitEmulator {
                        tempArm32EmuApps.append(model)
                    }
                }
            }
            // load document folders
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                // hasDirectoryPath 只看路径末尾有没有斜杠（纯字符串判断，
                // appendingPathComponent 拼出来的路径从来没有斜杠），
                // 在这里恒为 false，冷启动扫出来的注册表永远是空的——
                // 必须用 fileExists:isDirectory: 真去磁盘问（LCTweaksView 同款）。
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: LCPath.dataPath.appendingPathComponent(dataDir).path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }

            // load tweak folders
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: LCPath.tweakPath.appendingPathComponent(tweakDir).path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }

            // 共享（App Group）里的模块文件夹也要进注册表，否则转共享后
            // 模块页和选择器里永远看不到它们，重新开也恢复不了。
            // Group 还没建出来时这里抛错是正常的，静默跳过。
            do {
                let groupTweakDirs = try fm.contentsOfDirectory(atPath: LCPath.lcGroupTweakPath.path)
                for tweakDir in groupTweakDirs {
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: LCPath.lcGroupTweakPath.appendingPathComponent(tweakDir).path, isDirectory: &isDir), isDir.boolValue else {
                        continue
                    }
                    let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                    if !tempTweakFolderNames.contains(folderName) {
                        tempTweakFolderNames.append(folderName)
                    }
                }
            } catch {
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }

        return (tempApps, tempArm32EmuApps, tempHiddenApps, tempAppDataFolderNames, tempTweakFolderNames, tempURLSchemes)
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: "appView", for: String.self) { $id in
                if let id {
                    MultitaskAppWindow(id: id)
                }
            }

        }
    }
    
}
