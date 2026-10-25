//
//  LCMultitaskSettingView.swift
//  LiveContainer
//
//  Created by s s on 2026/3/21.
//

import SwiftUI

struct LCMultitaskSettingView: View {
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    @AppStorage("LCLaunchMultitaskMaximized") var launchMultitaskMaximized = false
    @AppStorage("LCMultitaskBottomWindowBar", store: LCUtils.appGroupUserDefault) var bottomWindowBar = false
    @AppStorage("LCAutoEndPiP", store: LCUtils.appGroupUserDefault) var autoEndPiP = false
    @AppStorage("LCSkipTerminatedScreen", store: LCUtils.appGroupUserDefault) var skipTerminatedScreen = false
    @AppStorage("LCRestartTerminatedApp", store: LCUtils.appGroupUserDefault) var restartTerminatedApp = false
    @AppStorage("LCMaxOneAppOnStage", store: LCUtils.appGroupUserDefault) var onlyOneAppOnStage = false
    @AppStorage("LCDockWidth", store: LCUtils.appGroupUserDefault) var dockWidth: Double = 80
    @AppStorage("LCHideCollapsedDock", store: LCUtils.appGroupUserDefault) var hideCollapsedDock: Bool = false
    // 隐藏快捷栏（CZF）：整条竖栏都不显示，有手势就够了；
    // 默认关（保持现有行为），开后快捷栏不再弹出
    @AppStorage("LCHideDock", store: LCUtils.appGroupUserDefault) var hideDock: Bool = false
    @AppStorage("LCRedirectURLToHost", store: LCUtils.appGroupUserDefault) var redirectURLToHost = false
    // 窗口状态还原（CZF）：关窗时记下窗口大小/位置/全屏状态，
    // 下次打开自动还原（DecoratedAppSceneViewController 读写，
    // 标准 UserDefaults，与那边 lcUserDefaults 同一本）
    @AppStorage("CZFRestoreWindowState") var restoreWindowState = true
    // 边缘手势（CZF）：总开关 + 灵敏度三档，宿主判定侧读取
    @AppStorage("CZFEdgeGesturesEnabled") var edgeGesturesEnabled = true
    @AppStorage("CZFEdgeSensitivity") var edgeSensitivity = 1

    var body: some View {
        List {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        Text("lc.settings.multitaskMode".loc)
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    Text("lc.settings.autoLaunchInMultitaskMode".loc)
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        Text("lc.settings.launchMultitaskMaximized".loc)
                    }
                    if launchMultitaskMaximized {
                        Toggle(isOn: $onlyOneAppOnStage) {
                            Text("lc.settings.onlyOneAppOnStage".loc)
                        }
                    }
                    Toggle(isOn: $autoEndPiP) {
                        Text("lc.settings.autoEndPiP".loc)
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        Text("lc.settings.skipTerminatedScreen".loc)
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            Text("lc.settings.restartTerminatedApp".loc)
                        }
                    }
                    Toggle(isOn: $bottomWindowBar) {
                        Text("lc.settings.bottomWindowBar".loc)
                    }
                    Toggle(isOn: $redirectURLToHost) {
                        Text("lc.settings.redirectURLToHost".loc)
                    }

                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("lc.settings.dockWidth".loc)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(Int(dockWidth))px")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    Slider(value: $dockWidth, in: 20...120) {
                        Text("lc.settings.dockWidth".loc)
                    }
                    .tint(.accentColor)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $hideCollapsedDock) {
                    Text("lc.settings.hideCollapsedDock".loc)
                }
                Toggle(isOn: $hideDock) {
                    Text("隐藏快捷栏")
                }
            }

            Section {
                Toggle(isOn: $restoreWindowState) {
                    Text("记住窗口位置")
                }
                Toggle(isOn: $edgeGesturesEnabled) {
                    Text("边缘手势")
                }
                if edgeGesturesEnabled {
                    Picker(selection: $edgeSensitivity) {
                        Text("低").tag(0)
                        Text("中").tag(1)
                        Text("高").tag(2)
                    } label: {
                        Text("手势灵敏度")
                    }
                }
            } header: {
                Text("窗口与手势")
            } footer: {
                Text("记住窗口位置：关掉 App 窗口时记下它的大小、位置和全屏状态，下次打开自动还原。手势灵敏度影响宿主侧的边缘启用范围和触发距离；低档更防误触，高档更好触发。")
            }
        }
        .navigationTitle("lc.appBanner.multitask".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}
