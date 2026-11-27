//  CZFQRCodeScannerView.swift
//  LiveContainerSwiftUI
//
//  3.8.722（F-1）：扫码添加源——相机扫含源 JSON 链接的二维码，
//  直接走现有 handleAddSource 加源。部署目标 iOS 15.0，不能用
//  iOS 16 的 DataScanner，用 AVFoundation AVCaptureSession +
//  .qr 元数据类型包一层 UIViewControllerRepresentable。
//  NSCameraUsageDescription 已在 LiveContainer/Info.plist，无需
//  新增权限文案。全仓此前无 QR/AVCapture 代码。

import AVFoundation
import SwiftUI
import UIKit

/// 扫码页（SwiftUI 包装）：扫到第一个二维码即停会话、回传字符串；
/// 取消走 onCancel；相机未授权时显示去设置的提示，不静默黑屏。
struct CZFQRCodeScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CZFQRScannerViewController {
        let vc = CZFQRScannerViewController()
        vc.onScanned = onScanned
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ uiViewController: CZFQRScannerViewController, context: Context) {}
}

final class CZFQRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var session: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(czfCancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
        ])

        let hintLabel = UILabel()
        hintLabel.text = "将源二维码对准取景框"
        hintLabel.textColor = .white
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupSession()
                    } else {
                        self?.showDenied()
                    }
                }
            }
        default:
            showDenied()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // sheet 尺寸/旋转变化时预览层跟住，否则画面只占初始 bounds。
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // startRunning 会阻塞，离主线程跑；viewDidLoad 里建好会话
        // 但还没跑时也在这里起，权限弹窗回来后同样能起。
        if let session, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
    }

    private func setupSession() {
        guard session == nil,
              let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // 只认二维码；回调走主队列，回调里直接调 onScanned（SwiftUI 侧接）。
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        output.metadataObjectTypes = [.qr]
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        self.previewLayer = previewLayer
        self.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    private func showDenied() {
        let label = UILabel()
        label.text = "相机权限未开启，请在设置里允许 LiveContainer 使用相机后重试"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        let settingsButton = UIButton(type: .system)
        settingsButton.setTitle("去设置开启", for: .normal)
        settingsButton.setTitleColor(.white, for: .normal)
        settingsButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        settingsButton.addTarget(self, action: #selector(czfOpenSettingsTapped), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(settingsButton)
        NSLayoutConstraint.activate([
            settingsButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
            settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    @objc private func czfCancelTapped() {
        onCancel?()
    }

    @objc private func czfOpenSettingsTapped() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // 只取第一个、只报一次：不置旗时同一码会每帧回调、重复加源。
        guard !didReport,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let str = obj.stringValue, !str.isEmpty else { return }
        didReport = true
        if let session, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
        onScanned?(str)
    }
}
