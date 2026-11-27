import Foundation
import SwiftUI

struct LCStorageManagementView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @StateObject private var model = LCStorageManagementModel()
    @State private var refreshed: Bool = false

    var body: some View {
        Form {
            LCStorageSummarySection(
                breakdown: model.breakdown,
                isCalculating: model.isCalculating,
                errorInfo: model.errorInfo,
                czfHiddenAppsInOther: model.czfHiddenAppsInOther
            )
            LCInstalledAppsSection(breakdown: model.breakdown)
        }
        .navigationTitle("lc.settings.storageManagement".loc)
        .navigationBarTitleDisplayMode(.inline)
        // 3.8.730（F-1）：手动刷新——原来只在进页 .task 算一次
        //（refreshed 守卫拦住重复计算），页内删 App、清缓存后数字
        // 一直是旧的，只能退出重进。下拉刷新 + 工具栏刷新按钮，
        // 都复用同一个 refresh()；算着的时候按钮禁用。
        .refreshable {
            await refresh()
            refreshed = true
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task {
                        await refresh()
                        refreshed = true
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isCalculating)
            }
        }
        .task {
            if !refreshed {
                await refresh()
                refreshed = true
            }

        }
    }

    private func refresh() async {
        await model.refresh(apps: sharedModel.apps, hiddenApps: sharedModel.hiddenApps)
    }
}
