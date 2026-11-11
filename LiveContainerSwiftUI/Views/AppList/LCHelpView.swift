//
//  LCHelpView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2025/1/4.
//

import SwiftUI

struct LCHelpView : View {
    @Binding var isPresent : Bool
    @State var helpURL = URL(string: "https://livecontainer.github.io/docs/faq")!
    
    var body: some View {
        VStack(spacing: 0) {
            SafariView(url: $helpURL)
            // 第三批低（App #27）：帮助页是纯在线 FAQ，没网时只有
            // Safari 的报错页，加一句离线提示。
            Text("帮助页需要联网才能打开，没网时请检查网络后重试。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
        }
    }
}
