//
//  ViewExtensions.swift
//  LiveContainer
//
//  Created by s s on 2026/3/20.
//

import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
import SafariServices
import Security
import Combine

struct SafariView: UIViewControllerRepresentable {
    let url: Binding<URL>
    func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> SFSafariViewController {
        return SFSafariViewController(url: url.wrappedValue)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: UIViewControllerRepresentableContext<SafariView>) {
        
    }
}

// https://stackoverflow.com/questions/56726663/how-to-add-a-textfield-to-alert-in-swiftui
extension View {

    public func textFieldAlert(
        isPresented: Binding<Bool>,
        title: String,
        text: Binding<String>,
        placeholder: String = "",
        action: @escaping (String?) -> Void,
        actionCancel: @escaping (String?) -> Void
    ) -> some View {
        self.modifier(TextFieldAlertModifier(isPresented: isPresented, title: title, text: text, placeholder: placeholder, action: action, actionCancel: actionCancel))
    }
    
    public func betterFileImporter(
        isPresented: Binding<Bool>,
        types : [UTType],
        multiple : Bool = false,
        callback: @escaping ([URL]) -> (),
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(DocModifier(isPresented: isPresented, types: types, multiple: multiple, callback: callback, onDismiss: onDismiss))
    }

    // 顶栏实底（3.8.424 修 424 红字）：.toolbarBackground 是
    // iOS 16+ 才有的 API，部署目标 15.0 下直接调编不过
    // （'toolbarBackground' is only available in iOS 16.0
    // or newer）。包一层 #available，iOS 16+ 走实底，15
    // 走默认玻璃顶栏。
    @ViewBuilder
    func czfSolidToolbarBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        } else {
            self
        }
    }

    // 文件夹选择器（3.8.423 本地 IPA 文件夹）：与 betterFileImporter
    // 同款 DocModifier 思路，但 asCopy 必须 false——文件夹不能
    // 拷一份（会把整个文件夹拷进临时目录、又大又不同步），要
    // 原位访问，靠 bookmark 持久化。选完回调给文件夹 URL，
    // 调用方自己 startAccessing + 存 bookmark。
    public func betterFolderImporter(
        isPresented: Binding<Bool>,
        callback: @escaping (URL) -> (),
        onDismiss: @escaping () -> Void
    ) -> some View {
        self.modifier(CZFFolderPickerModifier(isPresented: isPresented, callback: callback, onDismiss: onDismiss))
    }
    
    func onForeground(_ f: @escaping () -> Void) -> some View {
        self.onReceive(
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification),
            perform: { _ in f() }
        )
    }
    
    func rainbow() -> some View {
        self.modifier(RainbowAnimation())
    }
    
    func navigationBarProgressBar(show: Binding<Bool>, progress: Binding<Float>) -> some View {
        self.modifier(NavigationBarProgressModifier(show: show, progress: progress))
    }

    // 3.8.431 恢复：这不是死代码！MultitaskDockView.swift 有 3 处
    // .modifier { content in } 在用它（2757/3519/5058 行）。431 第三批
    // 误删了它，构建 12 条红字全挂在这。删前必须全仓 grep
    // ".modifier {"（含 MultitaskSupport/ 目录），只查
    // LiveContainerSwiftUI/ 会漏掉。
    func modifier<ModifiedContent: View>(@ViewBuilder body: (_ content: Self) -> ModifiedContent
    ) -> ModifiedContent {
        body(self)
    }

    // 3.8.317 修复：.presentationDetents 是 iOS 16+ API，部署目标
    // 15.0 下直接调用编不过（构建 #364 唯一红字）。包一层
    // #available，iOS 15 走默认 sheet 高度，iOS 16+ 强制满高。
    @ViewBuilder
    func czfPresentationDetentsLarge() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.large])
        } else {
            self
        }
    }
}

public struct DocModifier: ViewModifier {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State private var docController: UIDocumentPickerViewController?
    @State private var delegate : UIDocumentPickerDelegate
    
    @Binding var isPresented: Bool

    var callback: ([URL]) -> ()
    private let onDismiss: () -> Void
    private let types : [UTType]
    private let multiple : Bool
    
    init(isPresented : Binding<Bool>, types : [UTType], multiple : Bool, callback: @escaping ([URL]) -> (), onDismiss: @escaping () -> Void) {
        self.callback = callback
        self.onDismiss = onDismiss
        self.types = types
        self.multiple = multiple
        self._isPresented = isPresented
        // 3.8.428 #35：Coordinator 回调要复位 isPresented/docController。
        // struct 的 init 里 escaping 闭包不能抓 mutating self
        //（{ self.shutdown() } 编不过），改抓 isPresented 这个
        // Binding 本身（值类型，写 wrappedValue 直通父级状态）；
        // 置 false 后 onChange 走 handlePresentationChange(false)，
        // 在那里 dismiss 并把 docController 置 nil，效果与
        // shutdown() 相同。占位的那行已删，只留这一行。
        self.delegate = Coordinator(callback: callback, onDismiss: onDismiss, shutdown: { isPresented.wrappedValue = false })
    }

    public func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in
                handlePresentationChange(newValue)
            }
            .onAppear {
                // #34：isPresented 在挂载时已是 true 时 onChange 不触发，
                // 在这里补发一次，否则选文件框永远不弹。
                if isPresented {
                    handlePresentationChange(true)
                }
            }
    }

    private func handlePresentationChange(_ presented: Bool) {
        if presented, docController == nil {
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            controller.allowsMultipleSelection = multiple
            controller.delegate = delegate
            guard let rootViewController = sceneDelegate.window?.rootViewController, rootViewController.presentedViewController == nil else {
                // 已有 sheet/alert 在上面：UIKit 会静默丢弃本次 present。
                // 不把 isPresented 置 false、不占 docController，
                // 下次 onChange 再触发时重试，并留日志。
                print("[DocModifier] present skipped: rootViewController already presenting")
                return
            }
            self.docController = controller
            rootViewController.present(controller, animated: true)
        } else if !presented, let docController = docController {
            docController.dismiss(animated: true)
            self.docController = nil
        }
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var callback: ([URL]) -> ()
        private let onDismiss: () -> Void
        private let shutdown: () -> Void
        
        init(callback: @escaping ([URL]) -> Void, onDismiss: @escaping () -> Void, shutdown: @escaping () -> Void = {}) {
            self.callback = callback
            self.onDismiss = onDismiss
            self.shutdown = shutdown
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            callback(urls)
            shutdown()
            onDismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            shutdown()
            onDismiss()
        }
    }

}

public struct CZFFolderPickerModifier: ViewModifier {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State private var docController: UIDocumentPickerViewController?

    @Binding var isPresented: Bool
    var callback: (URL) -> ()
    private let onDismiss: () -> Void

    init(isPresented: Binding<Bool>, callback: @escaping (URL) -> (), onDismiss: @escaping () -> Void) {
        self.callback = callback
        self.onDismiss = onDismiss
        self._isPresented = isPresented
    }

    public func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in
                handlePresentationChange(newValue)
            }
            .onAppear {
                // #34：isPresented 在挂载时已是 true 时 onChange 不触发，
                // 在这里补发一次，否则文件夹选择器永远不弹。
                if isPresented {
                    handlePresentationChange(true)
                }
            }
    }

    private func handlePresentationChange(_ presented: Bool) {
        if presented, docController == nil {
            let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            controller.allowsMultipleSelection = false
            controller.delegate = Coordinator(callback: callback, onDismiss: onDismiss)
            guard let rootViewController = sceneDelegate.window?.rootViewController, rootViewController.presentedViewController == nil else {
                // 已有 sheet/alert 在上面：UIKit 会静默丢弃本次 present。
                // 不把 isPresented 置 false、不占 docController，
                // 下次 onChange 再触发时重试，并留日志。
                print("[CZFFolderPickerModifier] present skipped: rootViewController already presenting")
                return
            }
            self.docController = controller
            rootViewController.present(controller, animated: true)
        } else if !presented, let docController = docController {
            docController.dismiss(animated: true)
            self.docController = nil
        }
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var callback: (URL) -> ()
        private let onDismiss: () -> Void

        init(callback: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
            self.callback = callback
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { callback(url) }
            onDismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }
}

public struct TextFieldAlertModifier: ViewModifier {
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State private var alertController: UIAlertController?

    @Binding var isPresented: Bool

    let title: String
    let text: Binding<String>
    let placeholder: String
    let action: (String?) -> Void
    let actionCancel: (String?) -> Void

    public func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { newValue in
                handlePresentationChange(newValue)
            }
            .onAppear {
                // #34：isPresented 在挂载时已是 true 时 onChange 不触发，
                // 在这里补发一次，否则输入框永远不弹。
                if isPresented {
                    handlePresentationChange(true)
                }
            }
    }

    private func handlePresentationChange(_ presented: Bool) {
        if presented, alertController == nil {
            let alertController = makeAlertController()
            guard let rootViewController = sceneDelegate.window?.rootViewController, rootViewController.presentedViewController == nil else {
                // 已有 sheet/alert 在上面：UIKit 会静默丢弃本次 present。
                // 不把 isPresented 置 false、不占 alertController，
                // 下次 onChange 再触发时重试，并留日志。
                print("[TextFieldAlertModifier] present skipped: rootViewController already presenting")
                return
            }
            self.alertController = alertController
            rootViewController.present(alertController, animated: true)
        } else if !presented, let alertController = alertController {
            alertController.dismiss(animated: true)
            self.alertController = nil
        }
    }

    private func makeAlertController() -> UIAlertController {
        let controller = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        // 3.8.428 #35 同款：UIAlertAction 的 handler 是 escaping 闭包，
        // 不能在里面调 mutating 的 shutdown()（抓 mutating self 编不过）。
        // 先把 isPresented 这个 Binding 拷到局部量，闭包只抓它；
        // 注意必须用 $isPresented（投影值才是 Binding 本身），
        // 直接写 isPresented 拿到的是 Bool，.wrappedValue 编不过。
        // 置 false 后 onChange 走 handlePresentationChange(false)，
        // 在那里 dismiss 并把 alertController 置 nil。
        let czfIsPresented = $isPresented
        controller.addTextField {
            $0.placeholder = self.placeholder
            $0.text = self.text.wrappedValue
            $0.clearButtonMode = .always
        }
        controller.addAction(UIAlertAction(title: "lc.common.cancel".loc, style: .cancel) { _ in
            self.actionCancel(nil)
            czfIsPresented.wrappedValue = false
        })
        controller.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default) { _ in
            self.action(controller.textFields?.first?.text)
            czfIsPresented.wrappedValue = false
        })
        return controller
    }

}

struct NavigationBarProgressModifier: ViewModifier {
    @Binding var show: Bool
    @Binding var progress: Float

    func body(content: Content) -> some View {
        content
            .background(NavigationBarProgressView(show: $show, progress: $progress))
    }
}

private struct NavigationBarProgressView: UIViewControllerRepresentable {
    @Binding var show: Bool
    @Binding var progress: Float

    func makeUIViewController(context: Context) -> ProgressInjectorViewController {
        ProgressInjectorViewController(progress: progress)
    }

    func updateUIViewController(_ uiViewController: ProgressInjectorViewController, context: Context) {
        uiViewController.updateProgress(!show, progress)
    }

    class ProgressInjectorViewController: UIViewController {
        private var progressView: UIProgressView?
        // #36：init 收到的初始进度、以及注入前 updateProgress 送来的
        // 最新进度/隐藏态都要先存下来，注入后补设，否则早期进度
        // 会被 progressView == nil 的可选链静默丢掉。
        private var currentProgress: Float
        private var currentHidden: Bool = false

        init(progress: Float) {
            self.currentProgress = progress
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            injectProgressView()
        }

        func updateProgress(_ hidden: Bool, _ progress: Float) {
            currentHidden = hidden
            currentProgress = progress
            progressView?.setProgress(progress, animated: false)
            progressView?.isHidden = hidden
        }

        private func injectProgressView() {
            guard let navigationBar = self.navigationController?.navigationBar, progressView == nil else { return }

            let barProgress = UIProgressView(progressViewStyle: .bar)
            barProgress.translatesAutoresizingMaskIntoConstraints = false
            // #36：先把存下来的进度/隐藏态补设到新注入的进度条上。
            barProgress.setProgress(currentProgress, animated: false)
            barProgress.isHidden = currentHidden
            // #36：不再靠字符串匹配私有类名 "_UINavigationBarContentView"
            // 找内容视图（iOS 一改名进度条就悄悄消失），直接把进度条
            // 加到 navigationBar 上、用相对底部的约束定位。
            navigationBar.addSubview(barProgress)
            NSLayoutConstraint.activate([
                barProgress.leadingAnchor.constraint(equalTo: navigationBar.leadingAnchor),
                barProgress.trailingAnchor.constraint(equalTo: navigationBar.trailingAnchor),
                barProgress.bottomAnchor.constraint(equalTo: navigationBar.bottomAnchor)
            ])
            self.progressView = barProgress
        }

    }
}

// https://kieranb662.github.io/blog/2020/04/15/Rainbow
struct RainbowAnimation: ViewModifier {
    // 1
    @State var isOn: Bool = false
    // 第三批低 #59：响应减弱动态偏好——开启时不启动无限
    // 彩虹动画，直接显示静态内容。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hueColors = stride(from: 0, to: 1, by: 0.01).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }
    // 2
    var duration: Double = 4
    var animation: Animation {
        Animation
            .linear(duration: duration)
            .repeatForever(autoreverses: false)
    }

    func body(content: Content) -> some View {
    // 3
        let gradient = LinearGradient(gradient: Gradient(colors: hueColors+hueColors), startPoint: .leading, endPoint: .trailing)
        return content.overlay(GeometryReader { proxy in
            ZStack {
                gradient
    // 4
                    .frame(width: 2*proxy.size.width)
    // 5
                    .offset(x: self.isOn ? -proxy.size.width : 0)
            }
        })
    // 6
        .onAppear {
            // 第三批低 #59：减弱动态开启时不启动动画，isOn 保持
            // false，渐变停在初始位置、静态显示。
            guard !reduceMotion else { return }
            withAnimation(self.animation) {
                self.isOn = true
            }
        }
        .mask(content)
    }
}

struct BasicButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // #39：按压时给 0.6 透明度，否则所有用它的行点按零视觉反馈。
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

struct ActivityViewController: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: UIViewControllerRepresentableContext<ActivityViewController>) -> UIActivityViewController {
        return UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: UIViewControllerRepresentableContext<ActivityViewController>) {}
}

struct IconImageView: View {
    var icon: UIImage
    
    var body: some View {
        GeometryReader { g in
            Image(uiImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: g.size.width*0.2667))
        }
    }
}


extension UIViewController {
    func presentConfirmation(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String
    ) async -> Bool? {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else {
            return nil
        }

        return await withUnsafeContinuation { continuation in
            let finishConfirmation =  { (result: Bool?, alert: UIAlertController?) in
                alert?.dismiss(animated: true) {
                    continuation.resume(returning: result)
                }
            }
            
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { [weak alert] _ in
                finishConfirmation(true, alert)
            })
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { [weak alert] _ in
                finishConfirmation(false, alert)
            })
            present(alert, animated: true)
        }
    }

    func showError(_ message: String) {
        guard viewIfLoaded?.window != nil else {
            return
        }

        let presentError = { [weak self] in
            guard let self else {
                return
            }
            let alert = UIAlertController(title: "lc.common.error".loc, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "lc.common.ok".loc, style: .default))
            alert.addAction(UIAlertAction(title: "lc.common.copy".loc, style: .default) { _ in
                UIPasteboard.general.string = message
            })
            self.present(alert, animated: true)
        }

        if let presentedViewController {
            presentedViewController.dismiss(animated: true, completion: presentError)
        } else {
            presentError()
        }
    }
}
