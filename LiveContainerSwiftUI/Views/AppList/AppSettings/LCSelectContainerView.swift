//
//  LCSelectContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import SwiftUI

protocol LCSelectContainerViewDelegate {
    func addContainers(containers: Set<LCContainer>)
}

struct LCSelectContainerView : View{
    // 3.8.637（B2）：勾选集合直接存 LCContainer（Hashable 按实例
    // 身份）——只存 folderName 分不清两根同名夹：私人树与共享树
    // 可以有同名文件夹，它们是两个容器。
    @State private var multiSelection = Set<LCContainer>()
    @State private var unusedContainers : [LCContainer] = []
    @Binding var isPresent : Bool
    public var delegate : LCSelectContainerViewDelegate

    @EnvironmentObject private var sharedModel : SharedModel

    // 全选状态：未用容器全勾上了才算全选（空列表不算）。
    private var allContainersSelected: Bool {
        !unusedContainers.isEmpty && unusedContainers.allSatisfy { multiSelection.contains($0) }
    }

    var body: some View {
        NavigationView {
            List(selection: $multiSelection) {
                // 3.8.637（B2）：id 用实例本身（\.self，按身份哈希）——
                // 两根同名夹的 folderName 相同，用 folderName 作 id
                // 会撞 id、两行只显示一行。
                ForEach(unusedContainers, id: \.self) { container in
                    VStack(alignment: .leading) {
                        Text(container.name)
                        Text("\(container.folderName) - \(container.appIdentifier ?? "lc.container.selectUnused.unknownApp".loc)\(container.isShared ? "（共享）" : "（私人）")")
                            .font(.footnote)
                            .foregroundStyle(.gray)
                    }
                }
                if unusedContainers.count == 0 {
                    Text("lc.container.selectUnused.noUnused".loc)
                }
            }
            .environment(\.editMode, .constant(.active))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isPresent = false
                    } label: {
                        Text("lc.common.cancel".loc)
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button(allContainersSelected ? "取消全选" : "全选") {
                            if allContainersSelected {
                                multiSelection.removeAll()
                            } else {
                                multiSelection = Set(unusedContainers)
                            }
                        }
                        // 零勾选不显示“完成”（原来就只在勾了
                        // 才出现，零勾选走不下去，不用再禁）。
                        if multiSelection.count > 0 {
                            Button {
                                isPresent = false
                                delegate.addContainers(containers: multiSelection)
                            } label: {
                                Text("lc.common.done".loc)
                            }
                        }
                    }
                }
                
            }
            .navigationTitle(Text("lc.container.selectUnused".loc))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear() {
            loadUnusedContainers()
        }
        
    }
    
    func loadUnusedContainers() {
        // 3.8.637（B2）：两根都扫——原来只枚举私人树
        //（LCPath.dataPath = Documents/Data/Application），共享树
        //（LCPath.lcGroupDataPath，App Group 下同款路径）的旧数据夹
        // 永远不出现、接不回去。两根相同时只扫一遍。
        var appDataFolderNames: [(folderName: String, isShared: Bool)] = []
        multiSelection.removeAll()
        unusedContainers = []
        do {
            let fm = FileManager.default
            let roots: [(URL, Bool)] = LCPath.lcGroupDataPath != LCPath.dataPath
                ? [(LCPath.dataPath, false), (LCPath.lcGroupDataPath, true)]
                : [(LCPath.dataPath, false)]
            for (root, isShared) in roots {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let dataDirs = try fm.contentsOfDirectory(atPath: root.path)
                for dataDir in dataDirs {
                    // 冷启动扫描同款：hasDirectoryPath 只看路径末尾有没有斜杠，
                    // 拼出来的路径从来没有斜杠，在这里恒为 false、“未使用容器”
                    // 列表永远是空的——用 fileExists:isDirectory: 真去磁盘问。
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: root.appendingPathComponent(dataDir).path, isDirectory: &isDir), isDir.boolValue else {
                        continue
                    }
                    appDataFolderNames.append((dataDir, isShared))
                }
            }
        } catch {
            
        }

        
        // 3.8.637（B2）：已用判定按（isShared, folderName）分——
        // 同名夹在私人树已用，不代表共享树那只也已用，反之亦然。
        var folderKeyToAppDict : [String:LCAppModel] = [:]
        for app in sharedModel.apps {
            for container in app.appInfo.containers {
                folderKeyToAppDict[czfContainerKey(isShared: container.isShared, folderName: container.folderName)] = app;
            }
        }
        for app in sharedModel.hiddenApps {
            for container in app.appInfo.containers {
                folderKeyToAppDict[czfContainerKey(isShared: container.isShared, folderName: container.folderName)] = app;
            }
        }
        // 3.8.900（L595-C #1）：32 位 App 的容器也要排——只扫 apps + hiddenApps 时 arm32EmuApps 表里的文件夹恒判“未用”，会在别的 App 的添加列表里出现，登记后两 App 共用同一数据夹与同一钥匙串组（addContainers 只在组号 -1 时重分，合法组号原样保留）。
        for app in sharedModel.arm32EmuApps {
            for container in app.appInfo.containers {
                folderKeyToAppDict[czfContainerKey(isShared: container.isShared, folderName: container.folderName)] = app;
            }
        }
        
        var unusedFolders : [(folderName: String, isShared: Bool)]  = []
        for entry in appDataFolderNames {
            if folderKeyToAppDict[czfContainerKey(isShared: entry.isShared, folderName: entry.folderName)] == nil {
                unusedFolders.append(entry)
            }
        }
        
        unusedContainers = unusedFolders.map { folder in
            // 3.8.637（B2）：候选带上自己的 isShared——containerURL 按
            // isShared 分叉建，错了会挂到不存在的私人路径下、loadName
            // 静默无内容，等于接了个空容器。
            let ans = LCContainer(folderName: folder.folderName, name: folder.folderName, isShared: folder.isShared)
            ans.loadName()
            return ans;
        }
        
    }
}

// 3.8.637（B2）：（isShared, folderName）的字典键——folderName
// 里不会出现 \0，用它作分隔不会撞键。
private func czfContainerKey(isShared: Bool, folderName: String) -> String {
    "\(isShared ? "shared" : "private")\0\(folderName)"
}
