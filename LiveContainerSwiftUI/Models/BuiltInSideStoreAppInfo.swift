//
//  BuiltInSideStoreAppInfo.swift
//  LiveContainer
//
//  Created by s s on 2026/4/12.
//

final class BuiltInSideStoreAppInfo : LCAppInfo {
    static let shared = BuiltInSideStoreAppInfo()

    private override init() {
        super.init(bundlePath: Bundle.main.bundleURL.appendingPathComponent("Frameworks/SideStoreApp.framework").path)
    }
    
    override func iconIsDarkIcon(_ isDarkIcon: Bool) -> UIImage! {
        if isDarkIcon {
            if let cachedIconDark {
                return cachedIconDark
            }
            
        } else {
            if let cachedIcon {
                return cachedIcon
            }
        }
        guard let iconCacheUrl = ensureAndGetIconCacheFolder() else {
            return nil;
        }
        
        let cachedIconURL : URL;
        if(isDarkIcon) {
            cachedIconURL = iconCacheUrl.appendingPathComponent("LCAppIconDark.png");
        } else {
            cachedIconURL = iconCacheUrl.appendingPathComponent("LCAppIconLight.png");
        }
        
        var ans: UIImage? = nil
        if(FileManager.default.fileExists(atPath: cachedIconURL.path)) {
            ans = UIImage(contentsOfFile: cachedIconURL.path)
        }
        
        if let ans {
            // O-13：磁盘命中也写内存缓存，与 LCAppInfo.m 原版
            // 对称——否则每次 body 都重新读盘。
            if isDarkIcon {
                cachedIconDark = ans
            } else {
                cachedIcon = ans
            }
            return ans
        }
        
        ans = UIImage.generateIcon(forBundleURL: URL(fileURLWithPath: bundlePath()), style: isDarkIcon ? .Dark : .Light, hasBorder: true)
        if let ans {
            saveCGImage(ans.cgImage, cachedIconURL)
        }
        
        if isDarkIcon {
            cachedIconDark = ans
        } else {
            cachedIcon = ans
        }

        return ans;
    }

    // O-13：只读内存/磁盘缓存，不生成图标（供 CZFAppIconLoader
    // 快路径用；本类的磁盘缓存目录与 LCAppInfo.m 不同，
    // 不能走基类的 bundlePath/LCAppIcon*.png 路径）。
    func czfCachedIconOnly(isDarkIcon: Bool) -> UIImage? {
        if isDarkIcon {
            if let cachedIconDark {
                return cachedIconDark
            }
        } else {
            if let cachedIcon {
                return cachedIcon
            }
        }
        guard let iconCacheUrl = ensureAndGetIconCacheFolder() else {
            return nil
        }
        let cachedIconURL = iconCacheUrl.appendingPathComponent(isDarkIcon ? "LCAppIconDark.png" : "LCAppIconLight.png")
        guard FileManager.default.fileExists(atPath: cachedIconURL.path),
              let icon = UIImage(contentsOfFile: cachedIconURL.path) else {
            return nil
        }
        if isDarkIcon {
            cachedIconDark = icon
        } else {
            cachedIcon = icon
        }
        return icon
    }
    
    override var lastLaunched: Date!{
        get {
            return nil
        }
        
        set {
            
        }
    }
    
    private func ensureAndGetIconCacheFolder() -> URL? {
        let directory = LCPath.docPath
            .appendingPathComponent("SideStore/Library/Caches", isDirectory: true)
            .appendingPathComponent("BuiltInSideStoreIconCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return directory
    }
}
