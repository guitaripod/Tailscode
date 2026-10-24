import AVFoundation
import MidgarCore
import TailscodeCore
import UIKit

/// Reads the one code a machine prints when its install finishes. It looks for QR codes and
/// nothing else, hands the text of the first one to `onCode` exactly once, and stops the camera.
/// What the text means is not decided here: the setup screen feeds it to the same door a pasted
/// link goes through, so a code that is not a link is told so in plain words there.
///
/// Without the camera it is never a dead end: one line says why, and the way back to pasting the
/// link and the way to Settings are both on the screen.
@MainActor
final class QRScannerViewController: UIViewController {
    var onCode: ((String) -> Void)?
    var onPasteInstead: (() -> Void)?

    private let prompt: String
    private let engine = CaptureEngine()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let frameView = UIView()
    private let promptLabel = UILabel()
    private let deniedStack = UIStackView()
    private var delivered = false
    private var running = false

    init(prompt: String) {
        self.prompt = prompt
        previewLayer = AVCaptureVideoPreviewLayer(session: engine.session)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        buildUI()
        engine.output.setMetadataObjectsDelegate(self, queue: .main)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        authorizeAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
        previewLayer.connection?.videoRotationAngle = Self.rotationAngle(
            for: view.window?.windowScene?.interfaceOrientation ?? .portrait)
    }

    private static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        case .portraitUpsideDown: return 270
        default: return 90
        }
    }

    private func buildUI() {
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        frameView.layer.borderWidth = 3
        frameView.layer.cornerRadius = Theme.Radius.card
        frameView.layer.cornerCurve = .continuous
        frameView.isUserInteractionEnabled = false
        frameView.isAccessibilityElement = false

        promptLabel.text = prompt
        promptLabel.font = Theme.Ramp.font(.panelLabel)
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.textColor = .white
        promptLabel.textAlignment = .center
        promptLabel.numberOfLines = 0
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        let reason = SetupLink.label(
            Localized.text(
                "Camera access is off, so the code cannot be read. You can paste the link instead."),
            role: .panelLabel, color: .white)
        reason.textAlignment = .center
        let paste = PrimaryButton(title: Localized.text("Paste the link instead"))
        paste.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onPasteInstead?()
            }, for: .touchUpInside)
        let settings = SecondaryButton(title: Localized.text("Open Settings"))
        settings.addAction(
            UIAction { _ in
                Theme.Haptics.tap()
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)
        deniedStack.axis = .vertical
        deniedStack.spacing = Theme.Spacing.m
        deniedStack.isHidden = true
        deniedStack.translatesAutoresizingMaskIntoConstraints = false
        [reason, paste, settings].forEach(deniedStack.addArrangedSubview)

        view.addSubview(frameView)
        view.addSubview(promptLabel)
        view.addSubview(deniedStack)
        let side = frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7)
        side.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            side,
            frameView.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor),
            promptLabel.topAnchor.constraint(
                equalTo: frameView.bottomAnchor, constant: Theme.Spacing.l),
            promptLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            promptLabel.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            deniedStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            deniedStack.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            deniedStack.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @objc private func didBecomeActive() {
        guard view.window != nil else { return }
        authorizeAndStart()
    }

    private func authorizeAndStart() {
        guard !delivered else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.startCapture() } else { self.showUnavailable() }
                }
            }
        case .denied, .restricted:
            showUnavailable()
        @unknown default:
            showUnavailable()
        }
    }

    private func startCapture() {
        guard !running else { return }
        running = true
        setUnavailable(false)
        engine.start { [weak self] started in
            Task { @MainActor in
                guard let self else { return }
                if !started {
                    self.running = false
                    self.showUnavailable()
                }
            }
        }
    }

    private func stopCapture() {
        guard running else { return }
        running = false
        engine.stop()
    }

    private func showUnavailable() {
        MidgarLog.info("qr scanner: camera unavailable", category: .ui)
        setUnavailable(true)
        UIAccessibility.post(notification: .layoutChanged, argument: deniedStack)
    }

    private func setUnavailable(_ unavailable: Bool) {
        deniedStack.isHidden = !unavailable
        frameView.isHidden = unavailable
        promptLabel.isHidden = unavailable
        previewLayer.isHidden = unavailable
    }

    fileprivate func received(_ text: String) {
        guard !delivered else { return }
        delivered = true
        stopCapture()
        Theme.Haptics.success()
        MidgarLog.info("qr scanner: code read", category: .ui)
        onCode?(text)
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let text = metadataObjects.lazy.compactMap({
                ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue
            }).first
        else { return }
        MainActor.assumeIsolated { received(text) }
    }
}

private final class CaptureEngine: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "com.guitaripod.tailscode.qr-capture")
    private var configured = false

    func start(_ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard configure() else {
                completion(false)
                return
            }
            if !session.isRunning { session.startRunning() }
            completion(true)
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        output.metadataObjectTypes = [.qr]
        configured = true
        return true
    }
}
