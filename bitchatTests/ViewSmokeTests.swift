import Testing
import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import bitchat

@MainActor
@discardableResult
private func mount<V: View>(_ view: V) -> AnyObject {
    #if os(iOS)
    let host = UIHostingController(rootView: view)
    _ = host.view
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    return host
    #else
    let host = NSHostingView(rootView: view)
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    return host
    #endif
}

private func makeCGImage() throws -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let context = try #require(
        CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return try #require(context.makeImage())
}

@Suite("View Smoke Tests", .serialized)
@MainActor
struct ViewSmokeTests {
    @Test
    func qrViews_renderCoreBranches() throws {
        let qrCode = QRCodeImage(data: "bitchat://verify?hello=world", size: 96)
        let imageWrapper = ImageWrapper(image: try makeCGImage())

        _ = qrCode.body
        _ = imageWrapper.body
        _ = mount(qrCode)
        _ = mount(imageWrapper)
    }

    @Test
    func cameraScannerView_previewAndCoordinatorSmoke() {
        #if os(iOS) || os(macOS)
        // Synthetic availability keeps this smoke test off real capture hardware and TCC.
        let preview = CameraScannerView.PreviewView(frame: .zero)
        let coordinator = CameraScannerCoordinator(cameraAvailable: { false })

        #if os(iOS)
        _ = CameraScannerView.PreviewView.layerClass
        #elseif os(macOS)
        preview.layout()
        #endif
        _ = preview.videoPreviewLayer

        coordinator.setup(previewLayer: preview.videoPreviewLayer) { _ in }
        coordinator.setActive(false)
        coordinator.shutdown()

        #expect(preview.videoPreviewLayer.videoGravity == .resizeAspectFill)
        #endif
    }
}
