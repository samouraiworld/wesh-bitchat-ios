import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Échanger: your code on top and the camera below, active together,
/// so two people verify each other in one gesture.
struct PaveExchangeScreen: View {
    enum Camera {
        /// The live scanner; asks for permission on first use.
        case live
        /// A static viewfinder, for previews.
        case placeholder
    }

    let nickname: String
    /// Builds a fresh `bitchat://verify` payload; called again every five minutes.
    let makePayload: () -> String
    /// The contact's name, once known. Peer-chosen: shown only through `PaveDisplayName.safe(_:)`.
    var contactName: String?
    let progress: PaveExchangeProgress
    var camera: Camera = .live
    let onScan: (String) -> Void
    /// Called once, shortly after both checkmarks are in.
    let onComplete: () -> Void
    let onClose: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var payload = ""
    @State private var clock = PaveQRRefreshClock(issuedAt: .distantPast)
    @State private var now = Date()
    @State private var cameraBlocked: CameraBlock?
    @State private var completed = false

    enum CameraBlock {
        case denied, unavailable
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PaveSpace.s4) {
                header
                Text(PaveCopy.text("pave.exchange.intro"))
                    .paveText(.label)
                    .fontWeight(.regular)
                    .foregroundStyle(theme[.inkMuted])
                    .frame(maxWidth: .infinity, alignment: .leading)
                code
                Text(PaveCopy.text("pave.exchange.renews", nickname, clock.remainingMinutes(at: now)))
                    .paveText(.label)
                    .multilineTextAlignment(.center)
                scanner
                checkmarks
                Text(PaveCopy.text("pave.exchange.autoOpen"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, PaveSpace.s4)
            .padding(.bottom, PaveSpace.s8)
        }
        .paveScreenBackground()
        .task { await keepCodeFresh() }
        .onChange(of: progress) { newValue in
            guard newValue.isComplete, !completed else { return }
            completed = true
            PaveHaptics.play(.scanSuccess)
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                onComplete()
            }
        }
    }

    private var header: some View {
        HStack {
            Text(PaveCopy.text("pave.exchange.title")).paveText(.title).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(PaveTextStyle.headline.font)
                    .frame(width: PaveTouch.minimum, height: PaveTouch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PaveCopy.text("pave.action.close"))
        }
        .padding(.top, PaveSpace.s4)
    }

    private var code: some View {
        // Dark modules on a light quiet zone in both themes, framed by `private`.
        let quietZone: PaveColorRole = theme.id == .nuit ? .privateFill : .onPrivate
        return QRCodeImage(data: payload, size: 200)
            .frame(width: 200, height: 200)
            .padding(PaveSpace.s3)
            .background(theme[quietZone])
            .padding(PaveSpace.s4)
            .background(theme[.privateFill], in: RoundedRectangle(cornerRadius: PaveRadius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PaveCopy.text("pave.exchange.codeA11y", nickname))
            .padding(.vertical, PaveSpace.s2)
    }

    private var scanner: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PaveRadius.control).fill(theme[.surface])
            if let cameraBlocked {
                blockedCard(cameraBlocked)
            } else {
                viewfinder
            }
        }
        .frame(height: 220)
    }

    private var viewfinder: some View {
        ZStack {
            if camera == .live {
                CameraScannerView(isActive: !completed, onUnavailable: { cameraUnavailable() }) { scanned in
                    onScan(scanned)
                }
                .clipShape(RoundedRectangle(cornerRadius: PaveRadius.control))
            }
            RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(theme[.publicFill], lineWidth: PaveStroke.focus)
                .frame(width: 150, height: 150)
            VStack {
                Spacer()
                Text(PaveCopy.text("pave.exchange.aim"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.ink])
                    .padding(.horizontal, PaveSpace.s2)
                    .padding(.vertical, PaveSpace.s1)
                    .background(theme[.surface].opacity(0.85), in: Capsule())
                    .padding(.bottom, PaveSpace.s2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PaveCopy.text("pave.exchange.cameraA11y"))
    }

    private func blockedCard(_ block: CameraBlock) -> some View {
        VStack(spacing: PaveSpace.s3) {
            Label(PaveCopy.text(block == .denied ? "pave.exchange.cameraDenied" : "pave.exchange.cameraUnavailable"),
                  systemImage: "exclamationmark.triangle.fill")
                .paveText(.label)
                .foregroundStyle(theme[.warning])
                .multilineTextAlignment(.center)
            if block == .denied, let settings = PaveSystemSettings.url {
                Button(PaveCopy.text("pave.action.openSettings")) { openURL(settings) }
                    .buttonStyle(.paveSecondary)
            }
        }
        .padding(PaveSpace.s4)
    }

    private var checkmarks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PaveSpace.s3) { checkmarkChips }
            VStack(spacing: PaveSpace.s2) { checkmarkChips }
        }
    }

    @ViewBuilder private var checkmarkChips: some View {
        chip(done: progress.theyScannedMe,
             doneText: contactName.map { PaveCopy.text("pave.exchange.theyScannedNamed", PaveDisplayName.safe($0)) }
                ?? PaveCopy.text("pave.exchange.theyScanned"),
             pendingText: PaveCopy.text("pave.exchange.yourCode"))
        chip(done: progress.iScannedThem,
             doneText: contactName.map { PaveCopy.text("pave.exchange.iScannedNamed", PaveDisplayName.safe($0)) }
                ?? PaveCopy.text("pave.exchange.iScanned"),
             pendingText: PaveCopy.text("pave.exchange.theirCode"))
    }

    private func chip(done: Bool, doneText: String, pendingText: String) -> some View {
        Label(done ? doneText : pendingText, systemImage: done ? "checkmark.circle.fill" : "circle")
            .paveText(.label)
            .foregroundStyle(done ? theme[.success] : theme[.ink])
            .padding(.horizontal, PaveSpace.s4)
            .frame(minHeight: PaveTouch.minimum)
            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(done ? theme[.success] : theme[.lineStrong], lineWidth: PaveStroke.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(done ? doneText : PaveCopy.text("pave.exchange.pendingA11y", pendingText))
    }

    private func cameraUnavailable() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraBlocked = (status == .denied || status == .restricted) ? .denied : .unavailable
    }

    /// Renews the code when it expires and keeps the countdown current.
    private func keepCodeFresh() async {
        while !Task.isCancelled {
            now = Date()
            if payload.isEmpty || clock.isExpired(at: now) {
                payload = makePayload()
                clock = PaveQRRefreshClock(issuedAt: now)
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }
}

/// Deep link to this app's page in the system Settings.
enum PaveSystemSettings {
    static var url: URL? {
        #if os(iOS)
        return URL(string: UIApplication.openSettingsURLString)
        #else
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        #endif
    }
}

struct PaveExchangeScreen_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            PaveExchangeScreen(nickname: "Renard 42", makePayload: { "bitchat://verify?preview" },
                               contactName: "Nora", progress: PaveExchangeProgress(theyScannedMe: true, iScannedThem: false),
                               camera: .placeholder, onScan: { _ in }, onComplete: {}, onClose: {})
        }
    }
}
