import Combine
import Foundation
import UniformTypeIdentifiers

final class SharePayload: ObservableObject {
    enum Kind {
        case loading
        case url(URL)
        case file(URL)
        case empty
        case failed(String)
    }

    @Published var kind: Kind = .loading

    var sharedURL: URL? {
        if case .url(let url) = kind {
            return url
        }
        return nil
    }
    
    static func load(from context: NSExtensionContext?) async throws -> SharePayload.Kind {
        guard let items = context?.inputItems as? [NSExtensionItem] else {
            return .empty
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
                if let url = item as? URL {
                    return url.isFileURL ? .file(url) : .url(url)
                }
                if let data = item as? Data, let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                    return url.isFileURL ? .file(url) : .url(url)
                }
                if let string = item as? String, let url = URL(string: string) {
                    return url.isFileURL ? .file(url) : .url(url)
                }
            }
        }
        // L8：激活规则是 TRUEPREDICATE，纯文本分享也会进扩展（某些
        // App 只给 UTType.plainText）；旧代码只认 UTType.url，文本里
        // 的链接直接丢成 .empty、推荐为空。URL 项优先；没有时再从
        // 文本里抠第一个链接（NSDataDetector），抠不到才算空。
        // 文本是兜底路，读失败不抛错、直接落到 .empty。
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
                continue
            }
            guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) else {
                continue
            }
            let text: String?
            if let string = item as? String {
                text = string
            } else if let data = item as? Data {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }
            if let text,
               let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
               let match = detector.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
               let url = match.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return .url(url)
            }
        }
        return .empty
    }
}

struct ShareContainer: Identifiable, Hashable {
    let id: String
    let folderName: String
    let name: String
    let isShared: Bool
}

struct ShareApp: Identifiable, Hashable {
    let id: String
    let relativeBundlePath: String
    let displayName: String
    let bundleIdentifier: String
    let isShared: Bool
    let isHidden: Bool
    let isLocked: Bool
    let isJITNeeded: Bool
    let containers: [ShareContainer]
    let iconURL: URL?
    let lastLaunched: Date?
    let installationDate: Date?
    let isBuiltInSideStore: Bool

    var primaryContainer: ShareContainer? {
        containers.first
    }
}

struct ShareLaunchItem: Identifiable, Hashable {
    let app: ShareApp
    let container: ShareContainer

    var id: String {
        "\(app.id)|\(container.id)"
    }
}

struct ShareExtensionError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

// MARK: - App Group 收件箱（3.8.404）

/// 收件箱条目种类：一文件一条分享，文件名 `<UUID>.json`，
/// 扩展只写、主 App 前台认领后删除。URL 分享不另设 kind，
/// 链接字符串进 launch 条目的 launchURL（见 payloadPartsForInbox）。
enum CZFShareInboxKind: String, Codable {
    case file // 安装 IPA/tIPA：bookmarkBase64 + fileURLString
    case launch // 在客 App 里打开：bundleName + containerFolderName + launchURL
    case sidestore // 经内置 SideStore 打开：launchURL（文件时附 bookmarkBase64）
}

/// 收件箱条目。路径：`<AppGroup>/LiveContainer/ShareInbox/<UUID>.json`
///（AppGroup 由 LCSharedUtils.appGroupPath() 定，与主 App 的
/// LCPath.lcGroupDocPath 同一目录）。date 为 ISO8601 字符串。
struct CZFShareInboxEntry: Codable {
    var version: Int = 1
    var kind: CZFShareInboxKind
    var date: String
    var fileName: String?
    var fileExtension: String?
    var fileURLString: String?
    var bookmarkBase64: String?
    var bundleName: String?
    var containerFolderName: String?
    var launchURL: String?
}
