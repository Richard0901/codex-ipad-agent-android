import AVFoundation
import SwiftUI
import UIKit

enum QRCodeScannerRecoveryAction: Equatable {
    case openSettings
    case manualConnection
}

enum QRCodeScannerFailure: Equatable {
    case permissionDenied
    case permissionRestricted
    case cameraUnavailable
    case configurationFailed(String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "Mimi 没有相机权限，无法扫描 Mac 上的配对二维码。"
        case .permissionRestricted:
            return "当前设备限制了相机访问，无法扫描 Mac 上的配对二维码。"
        case .cameraUnavailable:
            return "当前设备没有可用于扫描二维码的相机。"
        case .configurationFailed(let reason):
            return reason
        }
    }

    var recoveryActions: [QRCodeScannerRecoveryAction] {
        switch self {
        case .permissionDenied, .permissionRestricted:
            return [.openSettings, .manualConnection]
        case .cameraUnavailable, .configurationFailed:
            return [.manualConnection]
        }
    }
}

struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scannerFailure: QRCodeScannerFailure?
    @State private var isCameraReady = false

    let onChooseManualConnection: () -> Void
    let onCode: (String) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                QRCodeScannerView { value in
                    onCode(value)
                    dismiss()
                } onError: { failure in
                    scannerFailure = failure
                } onReady: {
                    isCameraReady = true
                }

                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)

                if !isCameraReady {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("正在启动相机")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("如果系统弹出权限请求，请允许相机访问，用来扫描 Mac 上的配对二维码。")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("扫描配对二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        // 用户主动关闭不代表扫码失败，保持父页面原来的展开状态。
                        dismiss()
                    }
                }
            }
            .alert(
                "无法扫码",
                isPresented: scannerFailureBinding,
                presenting: scannerFailure
            ) { failure in
                if failure.recoveryActions.contains(.openSettings) {
                    Button("前往系统设置") {
                        openAppSettings()
                    }
                }
                Button("改用手动连接") {
                    chooseManualConnection()
                }
            } message: { failure in
                Text(failure.message)
            }
        }
    }

    private var scannerFailureBinding: Binding<Bool> {
        Binding(
            get: { scannerFailure != nil },
            set: { isPresented in
                if !isPresented {
                    scannerFailure = nil
                }
            }
        )
    }

    private func chooseManualConnection() {
        scannerFailure = nil
        // 父页面只负责展开已经存在的手动连接区域，扫码 Sheet 不复制连接表单和状态。
        onChooseManualConnection()
        dismiss()
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            chooseManualConnection()
            return
        }
        scannerFailure = nil
        dismiss()
        UIApplication.shared.open(url)
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (QRCodeScannerFailure) -> Void
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCode: onCode, onError: onError, onReady: onReady)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "MimiRemote.QRCodeScanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didReadCode = false

    private let onCode: (String) -> Void
    private let onError: (QRCodeScannerFailure) -> Void
    private let onReady: () -> Void

    init(
        onCode: @escaping (String) -> Void,
        onError: @escaping (QRCodeScannerFailure) -> Void,
        onReady: @escaping () -> Void
    ) {
        self.onCode = onCode
        self.onError = onError
        self.onReady = onReady
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCameraAccess()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    deinit {
        stopScanning()
    }

    private func prepareCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.reportFailure(.permissionDenied)
                    }
                }
            }
        case .denied:
            reportFailure(.permissionDenied)
        case .restricted:
            reportFailure(.permissionRestricted)
        @unknown default:
            reportFailure(.cameraUnavailable)
        }
    }

    private func configureSession() {
        guard previewLayer == nil else {
            startScanning()
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            reportFailure(.cameraUnavailable)
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                reportFailure(.configurationFailed("无法接入相机输入，请改用手动连接。"))
                return
            }
            captureSession.addInput(input)
        } catch {
            reportFailure(.configurationFailed("打开相机失败：\(error.localizedDescription)"))
            return
        }

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            reportFailure(.configurationFailed("当前相机不支持二维码扫描，请改用手动连接。"))
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
        reportReady()

        startScanning()
    }

    private func reportFailure(_ failure: QRCodeScannerFailure) {
        // Representable 创建和系统权限回调期间不能同步改写 SwiftUI State，统一延后到下一次主队列。
        DispatchQueue.main.async { [weak self] in
            self?.onError(failure)
        }
    }

    private func reportReady() {
        // 相机配置也可能发生在 makeUIViewController 链路内，同样异步交回 SwiftUI。
        DispatchQueue.main.async { [weak self] in
            self?.onReady()
        }
    }

    private func startScanning() {
        // AVCaptureSession 启停放到后台队列，避免设置页打开扫码时阻塞 SwiftUI 主线程。
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning {
                captureSession.startRunning()
            }
        }
    }

    private func stopScanning() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didReadCode,
              let object = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr }),
              let value = object.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return
        }

        // 第一次读到二维码后立刻停扫，防止同一个码连续触发多次连接测试。
        didReadCode = true
        stopScanning()
        onCode(value)
    }
}
