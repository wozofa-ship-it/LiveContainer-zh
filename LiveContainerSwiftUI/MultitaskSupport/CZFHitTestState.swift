//
//  CZFHitTestState.swift
//  LiveContainer
//
//  P0 hitTest 诊断（3.8.676）：topToolsExpanded 的只读镜像。
//  LCAppListView 的“更多工具”按钮在切换时同步写这里，诊断
//  日志读它；除这一行赋值外不参与任何逻辑。
//
import Foundation

enum CZFHitTestState {
    static var topToolsExpanded = false
}
