import SwiftUI

/// 数据管理页「储存总览」区：从 LCDataManagementView 拆出来的
/// 独立 Section（#20 拆类第一步）。总览只用自己的 4 个 @State
/// + 统计函数，跟备份/恢复列表互不牵连；备份总占用仍走整树
/// folderSize（总览只要一个总数），恢复 sheet 的按备份大小
/// 走 refreshBackupSizes 的单次遍历（见 #23），两边不重复扫
/// 同一棵树。PBXFileSystemSynchronizedRootGroup 下放进目录
/// 即自动进工程，不用改 project 文件。
struct LCStorageOverviewSection: View {
    @State private var storageBackupBytes: Int64 = -1
    @State private var storageIPAFiles: [(url: URL, size: Int64)] = []
    @State private var storageIPATotal: Int64 = 0
    @State private var showClearIPAsConfirm = false

    var body: some View {
        Section {
            if storageBackupBytes < 0 {
                Text("正在统计…")
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Text("备份占用")
                    Spacer()
                    Text(Self.sizeText(storageBackupBytes))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("已下载的 IPA（\(storageIPAFiles.count) 个）")
                    Spacer()
                    Text(Self.sizeText(storageIPATotal))
                        .foregroundColor(.secondary)
                }
                if !storageIPAFiles.isEmpty {
                    Button(role: .destructive) {
                        showClearIPAsConfirm = true
                    } label: {
                        Text("清理已下载的 IPA")
                    }
                }
            }
        } header: {
            Text("储存总览")
        } footer: {
            Text("「已下载的 IPA」是在源里点「下载」存进来的安装包，装完就没用了、可以放心清。每个 App 的数据占用明细在设置里的「存储管理」页看。")
        }
        .task {
            computeStorageStats()
        }
        .confirmationDialog("删除这 \(storageIPAFiles.count) 个已下载的 IPA（共 \(Self.sizeText(storageIPATotal))）？", isPresented: $showClearIPAsConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                for item in storageIPAFiles {
                    try? FileManager.default.removeItem(at: item.url)
                }
                computeStorageStats()
            }
            Button("lc.common.cancel".loc, role: .cancel) {}
        }
    }

    private static func sizeText(_ size: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return fmt.string(fromByteCount: size)
    }

    /// 储存总览统计：备份总占用 + Documents 根目录的 .ipa
    /// （源里「下载」存的位置）。各 App 数据占用不在这里重
    /// 复统计（「存储管理」页已有）。后台线程算完回主线程
    func computeStorageStats() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupsBytes = LCDataManagementView.folderSize(docs.appendingPathComponent("Backups"))
            var ipaFiles: [(url: URL, size: Int64)] = []
            if let entries = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
                for entry in entries where entry.pathExtension.lowercased() == "ipa" {
                    let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    ipaFiles.append((entry, size))
                }
            }
            let ipaTotal = ipaFiles.reduce(0) { $0 + $1.size }
            DispatchQueue.main.async {
                storageBackupBytes = backupsBytes
                storageIPAFiles = ipaFiles
                storageIPATotal = ipaTotal
            }
        }
    }
}
