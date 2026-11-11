import SwiftUI
import UIKit

final class ShareExtensionHandler: UIViewController {
    private let viewModel = ShareExtensionViewModel()
    private var host: UIHostingController<ShareExtensionRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 3.8.404：Share 不再打开主 App，launchResponder 不再接线
        //（属性保留只因 ActionExtensionHandler 还在设它，共用同一 ViewModel）。
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
