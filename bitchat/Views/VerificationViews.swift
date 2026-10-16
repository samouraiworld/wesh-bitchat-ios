import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Render a QR code image for a given string using CoreImage
struct QRCodeImage: View {
    let data: String
    let size: CGFloat
    @ThemedPalette private var palette

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    private enum Strings {
        static let unavailable: LocalizedStringKey = "verification.my_qr.unavailable"
    }

    var body: some View {
        Group {
            if let image = generateImage() {
                ImageWrapper(image: image)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(Strings.unavailable)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
                    )
            }
        }
    }

    private func generateImage() -> CGImage? {
        let inputData = Data(data.utf8)
        filter.message = inputData
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(1, Int(size / 32))
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(transformed, from: transformed.extent)
    }
}

// Platform-specific wrapper to display CGImage in SwiftUI
struct ImageWrapper: View {
    let image: CGImage
    var body: some View {
        #if os(iOS)
        let ui = UIImage(cgImage: image)
        return Image(uiImage: ui)
            .interpolation(.none)
            .resizable()
        #else
        let ns = NSImage(cgImage: image, size: .zero)
        return Image(nsImage: ns)
            .interpolation(.none)
            .resizable()
        #endif
    }
}


#if os(iOS)
struct CameraScannerView: UIViewRepresentable {
    typealias UIViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    /// Where codes are read, in the view's coordinates for a given size; nil reads the whole view.
    var regionOfInterest: ((CGSize) -> CGRect)? = nil
    /// Ignores every frame that reports more than one QR code.
    var requiresSingleCode = false
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable,
            regionOfInterest: regionOfInterest,
            requiresSingleCode: requiresSingleCode
        )
        let coordinator = context.coordinator
        view.onLayout = { [weak coordinator] size in coordinator?.layerDidLayout(size) }
        context.coordinator.setActive(isActive)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: CameraScannerCoordinator) {
        coordinator.shutdown()
        uiView.videoPreviewLayer.session = nil
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onLayout: ((CGSize) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#elseif os(macOS)
struct CameraScannerView: NSViewRepresentable {
    typealias NSViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    /// Where codes are read, in the view's coordinates for a given size; nil reads the whole view.
    var regionOfInterest: ((CGSize) -> CGRect)? = nil
    /// Ignores every frame that reports more than one QR code.
    var requiresSingleCode = false
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable,
            regionOfInterest: regionOfInterest,
            requiresSingleCode: requiresSingleCode
        )
        let coordinator = context.coordinator
        view.onLayout = { [weak coordinator] size in coordinator?.layerDidLayout(size) }
        context.coordinator.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ nsView: PreviewView, coordinator: CameraScannerCoordinator) {
        coordinator.shutdown()
        nsView.videoPreviewLayer.session = nil
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: NSView {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()
        var onLayout: ((CGSize) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            videoPreviewLayer.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.addSublayer(videoPreviewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            videoPreviewLayer.frame = bounds
            onLayout?(bounds.size)
        }
    }
}
#endif

final class CameraScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private var onCode: ((String) -> Void)?
    private var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.scanner.session")
    private var isDisposed = false
    private var isRunning = false
    private var permissionGranted = false
    private var desiredActive = false
    private var didConfigureSession = false
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private weak var metadataOutput: AVCaptureMetadataOutput?
    private var regionOfInterest: ((CGSize) -> CGRect)?
    private var requiresSingleCode = false
    private var layerSize: CGSize = .zero

    func setup(
        previewLayer: AVCaptureVideoPreviewLayer,
        onCode: @escaping (String) -> Void,
        onUnavailable: (() -> Void)? = nil,
        regionOfInterest: ((CGSize) -> CGRect)? = nil,
        requiresSingleCode: Bool = false
    ) {
        self.onCode = onCode
        self.onUnavailable = onUnavailable
        self.regionOfInterest = regionOfInterest
        self.requiresSingleCode = requiresSingleCode
        self.previewLayer = previewLayer
        previewLayer.session = session

        // Check authorization before creating AVCaptureDeviceInput so tests and
        // cold launches do not trigger a TCC prompt just by constructing input.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            if !configureSessionIfNeeded() {
                reportUnavailable()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    guard !self.isDisposed else { return }
                    self.permissionGranted = granted
                    if granted {
                        if !self.configureSessionIfNeeded() {
                            self.reportUnavailable()
                            return
                        }
                        if self.desiredActive && !self.isRunning {
                            self.setActive(true)
                        }
                    } else {
                        self.reportUnavailable()
                    }
                }
            }
        default:
            permissionGranted = false
            reportUnavailable()
        }
    }

    @discardableResult
    private func configureSessionIfNeeded() -> Bool {
        guard !didConfigureSession else { return true }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        metadataOutput = output
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        previewLayer?.session = session
        didConfigureSession = true
        return true
    }

    func layerDidLayout(_ size: CGSize) {
        layerSize = size
        applyRegionOfInterest()
    }

    /// Restricts detection to the region, converted to the output's coordinates. Valid once the
    /// session runs and the layer has a size, so it is applied again at both moments.
    private func applyRegionOfInterest() {
        guard let regionOfInterest, isRunning, layerSize.width > 0, layerSize.height > 0,
              let output = metadataOutput, let layer = previewLayer else { return }
        output.rectOfInterest = layer.metadataOutputRectConverted(fromLayerRect: regionOfInterest(layerSize))
    }

    private func reportUnavailable() {
        DispatchQueue.main.async {
            guard !self.isDisposed else { return }
            self.onUnavailable?()
        }
    }

    func shutdown() {
        setActive(false)
        isDisposed = true
        onCode = nil
        onUnavailable = nil
        previewLayer = nil
    }

    func setActive(_ active: Bool) {
        guard !isDisposed else { return }
        desiredActive = active
        guard permissionGranted, didConfigureSession else { return }
        if active && !isRunning {
            isRunning = true
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.applyRegionOfInterest() }
            }
        } else if !active && isRunning {
            isRunning = false
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard desiredActive, !isDisposed else { return }
        if requiresSingleCode {
            // A second code in the same frame could be someone else's: read nothing.
            let codes = metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }
                .filter { $0.type == .qr }
                .map(\.stringValue)
            if let code = PaveScanArea.singleCode(codes) { onCode?(code) }
            return
        }
        for obj in metadataObjects {
            guard let m = obj as? AVMetadataMachineReadableCodeObject,
                  m.type == .qr,
                  let str = m.stringValue else { continue }
            onCode?(str)
        }
    }
}
