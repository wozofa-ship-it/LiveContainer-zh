//
//  LCSelectContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import SwiftUI

protocol LCSelectContainerViewDelegate {
    func addContainers(containers: Set<String>)
}

struct LCSelectContainerView : View{
    @State private var multiSelection = Set<String>()
    @State private var unusedContainers : [LCContainer] = []
    @Binding var isPresent : Bool
    public var delegate : LCSelectContainerViewDelegate

    @EnvironmentObject private var sharedModel : SharedModel

    // 全选状态：未用容器全勾上了才算全选（空列表不算）。
    private var allContainersSelected: Bool {
        !unusedContainers.isEmpty && unusedContainers.allSatisfy { multiSelection.contains($0.folderName) }
    }

    var body: some View {
        NavigationView {
            List(selection: $multiSelection) {
                ForEach(unusedContainers, id: \.folderName) { container in
                    VStack(alignment: .leading) {
                        Text(container.name)
                        Text("\(container.folderName) - \(container.appIdentifier ?? "lc.container.selectUnused.unknownApp".loc)")
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
                                multiSelection = Set(unusedContainers.map { $0.folderName })
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
        // load document folders
        var appDataFolderNames: [String] = []
        multiSelection.removeAll()
        unusedContainers = []
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                // 冷启动扫描同款：hasDirectoryPath 只看路径末尾有没有斜杠，
                // 拼出来的路径从来没有斜杠，在这里恒为 false、“未使用容器”
                // 列表永远是空的——用 fileExists:isDirectory: 真去磁盘问。
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: LCPath.dataPath.appendingPathComponent(dataDir).path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }
                appDataFolderNames.append(dataDir)
            }
        } catch {
            
        }

        
        var folderNameToAppDict : [String:LCAppModel] = [:]
        for app in sharedModel.apps {
            for container in app.appInfo.containers {
                folderNameToAppDict[container.folderName] = app;
            }
        }
        for app in sharedModel.hiddenApps {
            for container in app.appInfo.containers {
                folderNameToAppDict[container.folderName] = app;
            }
        }
        
        var unusedFolders : [String]  = []
        for appDataFolderName in appDataFolderNames {
            if folderNameToAppDict[appDataFolderName] == nil {
                unusedFolders.append(appDataFolderName)
            }
        }
        
        unusedContainers = unusedFolders.map { folder in
            let ans = LCContainer(folderName: folder, name: folder, isShared: false)
            ans.loadName()
            return ans;
        }
        
    }
}
