import SwiftUI
import UIKit

final class ActionExtensionHandler: UIViewController {
    private let viewModel = ShareExtensionViewModel()
    private var host: UIHostingController<ShareExtensionRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 3.8.381：Action 扩展的起点，与 ShareExtensionHandler
        // 同款接线（同一 ViewModel + 同一选 App 界面）。唯一
        // 不同：只走响应链打开（Apollo PR #307 实证），
        // context.open 在 Share 上已证实走不通，这里直接跳过。
        viewModel.launchResponder = self
        viewModel.responderChainOnly = true
        let root = ShareExtensionRootView(viewModel: viewModel, extensionContext: extensionContext)
        let host = UIHostingController(rootView: root)
        self.host = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        viewModel.loadPayload(from: extensionContext)
    }

    override func beginRequest(with context: NSExtensionContext) {
        viewModel.loadPayload(from: context)
    }
}
