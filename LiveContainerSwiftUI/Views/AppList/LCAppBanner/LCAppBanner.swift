//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
    // 3.8.682（F1）：备份这个 App——列表模式长按菜单入口，唯一实现
    // 方 LCAppListView（单项写入批量选中 + 弹批量备份范围单）。
    func backupApp(app: LCAppModel)
    // 3.8.726（F-1）：恢复这个 App——列表模式长按菜单入口，唯一实现
    // 方 LCAppListView（单项写入批量选中 + 弹批量恢复范围单）。
    func restoreApp(app: LCAppModel)
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate
    // F1（3.8.635）：签名剩余天数（nil = 没读到，不显示）。
    var expiryDaysLeft: Int? = nil
    // 3.8.684（B1）：批量模式——批量态下横幅不弹长按菜单、不开
    // 多任务面板；默认 false，其余调用点（网格等）不用改。
    var batchMode: Bool = false

    @ObservedObject var model: LCAppModel

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    private let sharedModel = DataManager.shared.model

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, expiryDaysLeft: Int? = nil, batchMode: Bool = false) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
        self.expiryDaysLeft = expiryDaysLeft
        self.batchMode = batchMode
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = LCAppBannerViewController(delegate: delegate, config: LCAppBannerConfiguration(model: model, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, expiryDaysLeft: expiryDaysLeft))
        // 3.8.684（B1）：批量态下行到控制器（门只加在这里）。
        viewController.czfBatchMode = batchMode
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let viewController = uiViewController as? LCAppBannerViewController else {
            return
        }
        // 3.8.684（B1）：进出批量态即同步，控制器不自己猜。
        viewController.czfBatchMode = batchMode
        viewController.update(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            expiryDaysLeft: expiryDaysLeft
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        return CGSize(width: width, height: LCAppBannerRootView.bannerHeight)
    }
}
