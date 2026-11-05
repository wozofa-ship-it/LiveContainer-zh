//
//  LCAppGroupsView.swift
//  LiveContainerSwiftUI
//
//  新2（3.8.277）：App 分组管理页。上下拖动调整分组顺序；
// 长按分组改名/删除（删除后组内 App 回“未分组”）；
// 归组走 App 行长按菜单“移到分组”，不在这里做。
//
import SwiftUI

struct LCAppGroupsView: View {
    @EnvironmentObject private var manager: LCAppSortManager
    @Environment(\.presentationMode) var presentationMode

    @State private var newGroupName = ""
    @State private var renamingName: String? = nil
    @State private var renameText = ""

    private var renameInvalid: Bool {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let renamingName else { return true }
        return trimmed.isEmpty || trimmed == renamingName || trimmed == LCAppSortManager.ungroupedName || manager.groups.contains(trimmed)
    }

    private func memberCount(of name: String) -> Int {
        manager.groupMembers.values.filter { $0 == name }.count
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(manager.groups, id: \.self) { name in
                        if renamingName == name {
                            HStack {
                                TextField("分组名", text: $renameText)
                                Button("保存") {
                                    if manager.renameGroup(from: name, to: renameText) {
                                        renamingName = nil
                                    }
                                }
                                .disabled(renameInvalid)
                                Button("取消") { renamingName = nil }
                            }
                        } else {
                            HStack {
                                Text(name)
                                Spacer()
                                Text("\(memberCount(of: name)) 个")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contextMenu {
                                Button("改名") {
                                    renameText = name
                                    renamingName = name
                                }
                                Button("删除", role: .destructive) {
                                    _ = manager.deleteGroup(named: name)
                                }
                            }
                        }
                    }
                    .onMove { source, destination in
                        manager.moveGroup(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("分组")
                } footer: {
                    Text("上下拖动调整分组顺序；长按分组可改名或删除，删除后组内 App 回“未分组”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack {
                        TextField("新分组名", text: $newGroupName)
                        Button("新增") {
                            if manager.addGroup(named: newGroupName) {
                                newGroupName = ""
                            }
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newGroupName.trimmingCharacters(in: .whitespacesAndNewlines) == LCAppSortManager.ungroupedName || manager.groups.contains(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } footer: {
                    Text("在 App 行上长按 → 移到分组，即可把 App 归进分组。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("管理分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }
}
