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
    // 最小化省电（CZF）：两条都有开关，默认都开，关了即回旧行为。
    // 键在 appGroup，ObjC 侧（Decorated）和 Swift 侧（DockManager）
    // 按“键不存在 = 开”同款读法，@AppStorage 初始值 true 与之对齐。
    @AppStorage("CZFMinPowerSavingEnabled", store: LCUtils.appGroupUserDefault) var minPowerSavingEnabled = true
    @AppStorage("CZFMinAutoCloseEnabled", store: LCUtils.appGroupUserDefault) var minAutoCloseEnabled = true

    var body: some View {
        List {
            Section {
                if(UIApplication.shared.supportsMultipleScenes) {
                    Picker(selection: $multitaskMode) {
                        Text("lc.settings.multitaskMode.virtualWindow".loc).tag(MultitaskMode.virtualWindow)
                        Text("lc.settings.multitaskMode.nativeWindow".loc).tag(MultitaskMode.nativeWindow)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "rectangle.stack", color: .purple)
                            Text("lc.settings.multitaskMode".loc)
                        }
                    }
                }
                Toggle(isOn: $launchInMultitaskMode) {
                    HStack {
                        LCSettingsIcon(systemName: "play.fill", color: .green)
                        Text("lc.settings.autoLaunchInMultitaskMode".loc)
                    }
                }
                
                if multitaskMode == .virtualWindow {
                    Toggle(isOn: $launchMultitaskMaximized) {
                        HStack {
                            LCSettingsIcon(systemName: "arrow.up.left.and.arrow.down.right", color: .blue)
                            Text("lc.settings.launchMultitaskMaximized".loc)
                        }
                    }
                    if launchMultitaskMaximized {
                        Toggle(isOn: $onlyOneAppOnStage) {
                            HStack {
                                LCSettingsIcon(systemName: "square.stack", color: .purple)
                                Text("lc.settings.onlyOneAppOnStage".loc)
                            }
                        }
                    }
                    Toggle(isOn: $autoEndPiP) {
                        HStack {
                            LCSettingsIcon(systemName: "pip", color: .gray)
                            Text("lc.settings.autoEndPiP".loc)
                        }
                    }
                    Toggle(isOn: $skipTerminatedScreen) {
                        HStack {
                            LCSettingsIcon(systemName: "forward.fill", color: .gray)
                            Text("lc.settings.skipTerminatedScreen".loc)
                        }
                    }
                    if skipTerminatedScreen {
                        Toggle(isOn: $restartTerminatedApp) {
                            HStack {
                                LCSettingsIcon(systemName: "arrow.clockwise", color: .green)
                                Text("lc.settings.restartTerminatedApp".loc)
                            }
                        }
                    }
                    Toggle(isOn: $bottomWindowBar) {
                        HStack {
                            LCSettingsIcon(systemName: "menubar.rectangle", color: .gray)
                            Text("lc.settings.bottomWindowBar".loc)
                        }
                    }
                    Toggle(isOn: $redirectURLToHost) {
                        HStack {
                            LCSettingsIcon(systemName: "link", color: .blue)
                            Text("lc.settings.redirectURLToHost".loc)
                        }
                    }

                }
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        LCSettingsIcon(systemName: "rectangle.expand.horizontal", color: .blue)
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
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash", color: .gray)
                        Text("lc.settings.hideCollapsedDock".loc)
                    }
                }
                Toggle(isOn: $hideDock) {
                    HStack {
                        LCSettingsIcon(systemName: "eye.slash.fill", color: .red)
                        Text("隐藏快捷栏")
                    }
                }
            }

            Section {
                Toggle(isOn: $minPowerSavingEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "moon.fill", color: .indigo)
                        Text("最小化进后台省电")
                    }
                }
                Toggle(isOn: $minAutoCloseEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "timer", color: .red)
                        Text("最小化超 30 分钟自动关")
                    }
                }
            } header: {
                Text("最小化省电")
            } footer: {
                Text("最小化进后台：窗口最小化后把它的场景置为后台，让它自己停渲染、停视频、停定时器，叫回台前自动恢复前台；画中画不受影响。超 30 分钟自动关：最小化满 30 分钟还没叫回来就直接关窗，彻底停掉；恢复可见后重新计 30 分钟，画中画豁免。两条关了都回旧行为：最小化只藏视图、一直以前台跑。")
            }

            Section {
                Toggle(isOn: $restoreWindowState) {
                    HStack {
                        LCSettingsIcon(systemName: "clock.fill", color: .orange)
                        Text("记住窗口位置")
                    }
                }
                Toggle(isOn: $edgeGesturesEnabled) {
                    HStack {
                        LCSettingsIcon(systemName: "hand.draw.fill", color: .blue)
                        Text("边缘手势")
                    }
                }
                if edgeGesturesEnabled {
                    Picker(selection: $edgeSensitivity) {
                        Text("低").tag(0)
                        Text("中").tag(1)
                        Text("高").tag(2)
                    } label: {
                        HStack {
                            LCSettingsIcon(systemName: "slider.horizontal.3", color: .purple)
                            Text("手势灵敏度")
                        }
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
