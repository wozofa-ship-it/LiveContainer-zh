//
//  LCAppSortSchemesView.swift
//  LiveContainerSwiftUI
//
//  新1（3.8.277）：多套排序方案管理页。点方案即切换到它的顺序
// （写进 customSortOrder 并置 .custom）；长按改名/删除；
// 新增方案从空顺序起。至少留一套，删最后一套不允许。
//
import SwiftUI

struct LCAppSortSchemesView: View {
    @EnvironmentObject private var manager: LCAppSortManager
    @Environment(\.presentationMode) var presentationMode

    @State private var newSchemeName = ""
    @State private var renamingName: String? = nil
    @State private var renameText = ""

    private var renameInvalid: Bool {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let renamingName else { return true }
        return trimmed.isEmpty || trimmed == renamingName || manager.schemes[trimmed] != nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    ForEach(manager.schemes.keys.sorted(), id: \.self) { name in
                        if renamingName == name {
                            HStack {
                                TextField("方案名", text: $renameText)
                                Button("保存") {
                                    if manager.renameScheme(from: name, to: renameText) {
                                        renamingName = nil
                                    }
                                }
                                .disabled(renameInvalid)
                                Button("取消") { renamingName = nil }
                            }
                        } else {
                            HStack {
                                Button {
                                    manager.switchScheme(to: name)
                                    presentationMode.wrappedValue.dismiss()
                                } label: {
                                    HStack {
                                        Text(name)
                                        Spacer()
                                        Text("\(manager.schemes[name]?.count ?? 0) 个")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if name == manager.currentSchemeName {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .contextMenu {
                                Button("改名") {
                                    renameText = name
                                    renamingName = name
                                }
                                Button("删除", role: .destructive) {
                                    _ = manager.deleteScheme(named: name)
                                }
                                .disabled(manager.schemes.count <= 1)
                            }
                        }
                    }
                } header: {
                    Text("排序方案")
                } footer: {
                    Text("点方案即切换到它的顺序；长按方案可改名或删除（至少留一套）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack {
                        TextField("新方案名，如 游戏", text: $newSchemeName)
                        Button("新增") {
                            if manager.addScheme(named: newSchemeName) {
                                newSchemeName = ""
                            }
                        }
                        .disabled(newSchemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.schemes[newSchemeName.trimmingCharacters(in: .whitespacesAndNewlines)] != nil)
                    }
                } footer: {
                    Text("新方案从空顺序起，列表先按字母序显示，拖动后即为该方案的顺序。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("排序方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}
