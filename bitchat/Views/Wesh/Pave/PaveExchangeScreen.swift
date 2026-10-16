import AVFoundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Échanger: your code on top and the camera below, active together,
/// so two people verify each other in one gesture. Your fingerprint sits under your code; once both
/// checks are in, a success card shows the contact's name with its fingerprint, so the nickname is
/// never the only identity cue. The checks never show a name.
struct PaveExchangeScreen: View {
    enum Camera {
        /// The live scanner; asks for permission on first use.
        case live
        /// A static viewfinder, for previews.
        case placeholder
    }

    let nickname: String
    /// Your Noise static key; its short fingerprint is computed off the main thread.
    let myNoiseKey: Data?
    /// Builds a fresh `bitchat://verify` payload; called again every five minutes.
    let makePayload: () -> String
    /// The contact's name, once known. Peer-chosen: shown only through `PaveDisplayName.safe(_:)`.
    var contactName: String?
    /// The contact's verified Noise static key, once known; its fingerprint shows on success.
    var contactNoiseKey: Data?
    let progress: PaveExchangeProgress
    var camera: Camera = .live
    let onScan: (String) -> Void
    /// Called once: on « Ouvrir la discussion », or three seconds after both checkmarks are in.
    let onComplete: () -> Void
    let onClose: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var payload = ""
    @State private var clock = PaveQRRefreshClock(issuedAt: .distantPast)
    @State private var now = Date()
    @State private var cameraUnavailable = false
    @State private var authorization = PaveCameraAuthorization.current
    @State private var latch = PaveCompletionLatch()
    @State private var myFingerprint: String?
    @State private var contactFingerprint: String?

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
                Text(PaveCopy.text("pave.exchange.renews", PaveDisplayName.safe(nickname), clock.remainingMinutes(at: now)))
                    .paveText(.label)
                    .multilineTextAlignment(.center)
                PaveFingerprintBlock(label: PaveCopy.text("pave.fingerprint.mine"), fingerprint: fingerprints.mine)
                if progress.isComplete {
                    successCard
                } else {
                    scanner
                }
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
        .task(id: myNoiseKey) { myFingerprint = await PaveFingerprint.computed(myNoiseKey) }
        .task(id: contactNoiseKey) { contactFingerprint = await PaveFingerprint.computed(contactNoiseKey) }
        .task(id: progress.isComplete) {
            // Cancelled when the screen goes away; Close also shuts the latch.
            guard progress.isComplete else { return }
            PaveHaptics.play(.scanSuccess)
            do {
                try await Task.sleep(nanoseconds: UInt64(PaveCompletionLatch.successHold * 1_000_000_000))
            } catch {
                return
            }
            openChat()
        }
    }

    private func close() {
        latch.close()
        onClose()
    }

    private var fingerprints: PaveExchangeFingerprints {
        PaveExchangeFingerprints(mine: myFingerprint, contact: contactFingerprint, progress: progress)
    }

    /// The button and the timer both lead here; the chat opens once.
    private func openChat() {
        latch.fire { onComplete() }
    }

    private var successCard: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s2) {
            Label(PaveCopy.text("pave.exchange.success"), systemImage: "checkmark.seal.fill")
                .paveText(.label)
                .foregroundStyle(theme[.success])
            Text(PaveDisplayName.safe(contactName))
                .paveText(.headline)
                .lineLimit(2)
            PaveFingerprintBlock(label: PaveCopy.text("pave.fingerprint.contact"), fingerprint: fingerprints.contact)
            Button(PaveCopy.text("pave.exchange.openChat")) { openChat() }
                .buttonStyle(.pavePrimary)
        }
        .padding(PaveSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
            .strokeBorder(theme[.success], lineWidth: PaveStroke.control))
    }

    private var header: some View {
        HStack {
            Text(PaveCopy.text("pave.exchange.title")).paveText(.title).accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) {
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
            .accessibilityLabel(PaveCopy.text("pave.exchange.codeA11y", PaveDisplayName.safe(nickname)))
            .padding(.vertical, PaveSpace.s2)
    }

    private var scanner: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PaveRadius.control).fill(theme[.surface])
            if camera == .placeholder {
                viewfinder
            } else if cameraUnavailable {
                blockedCard(text: PaveCopy.text("pave.exchange.cameraUnavailable"), showsSettings: false)
            } else {
                switch PaveCameraCard(authorization) {
                case .scanner: viewfinder
                case .rationale: rationaleCard
                case .settings: blockedCard(text: PaveCopy.text("pave.exchange.cameraDenied"), showsSettings: true)
                }
            }
        }
        .frame(minHeight: 220)
    }

    /// Before any system prompt: why the camera, and the only button that asks for it.
    private var rationaleCard: some View {
        VStack(spacing: PaveSpace.s3) {
            Image(systemName: "camera.fill")
                .font(PaveTextStyle.headline.font)
                .accessibilityHidden(true)
            Text(PaveCopy.text("pave.exchange.cameraRationale"))
                .paveText(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(PaveCopy.text("pave.exchange.cameraAllow")) {
                AVCaptureDevice.requestAccess(for: .video) { _ in
                    Task { @MainActor in authorization = .current }
                }
            }
            .buttonStyle(.paveSecondary)
        }
        .foregroundStyle(theme[.ink])
        .padding(PaveSpace.s4)
    }

    private var viewfinder: some View {
        ZStack {
            if camera == .live {
                CameraScannerView(isActive: !progress.isComplete, onUnavailable: { scannerUnavailable() }) { scanned in
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

    private func blockedCard(text: String, showsSettings: Bool) -> some View {
        VStack(spacing: PaveSpace.s3) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .paveText(.label)
                .foregroundStyle(theme[.warning])
                .multilineTextAlignment(.center)
            if showsSettings, let settings = PaveSystemSettings.url {
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

    /// Never a name here: a check is a trust signal, the name is peer-chosen.
    @ViewBuilder private var checkmarkChips: some View {
        chip(done: progress.theyScannedMe, check: .yourCode)
        chip(done: progress.iScannedThem, check: .theirCode)
    }

    private func chip(done: Bool, check: PaveExchangeCheck) -> some View {
        let doneText = check.label(done: true)
        let pendingText = check.label(done: false)
        return Label(done ? doneText : pendingText, systemImage: done ? "checkmark.circle.fill" : "circle")
            .paveText(.label)
            .foregroundStyle(done ? theme[.success] : theme[.ink])
            .padding(.horizontal, PaveSpace.s4)
            .frame(minHeight: PaveTouch.minimum)
            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(done ? theme[.success] : theme[.lineStrong], lineWidth: PaveStroke.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(done ? doneText : PaveCopy.text("pave.exchange.pendingA11y", pendingText))
    }

    private func scannerUnavailable() {
        authorization = .current
        if authorization == .authorized { cameraUnavailable = true }
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

/// `label` (whose key it is) above a short fingerprint in monospace; VoiceOver reads it one
/// character at a time.
struct PaveFingerprintBlock: View {
    let label: String
    let fingerprint: String?
    @Environment(\.paveTheme) private var theme

    var body: some View {
        VStack(spacing: PaveSpace.s1) {
            if let fingerprint {
                Text(label).paveText(.caption).foregroundStyle(theme[.inkMuted])
                Text(verbatim: fingerprint)
                    .paveText(.fingerprint)
                    .foregroundStyle(theme[.ink])
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            } else {
                Text(PaveCopy.text("pave.fingerprint.unavailable")).paveText(.caption).foregroundStyle(theme[.warning])
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fingerprint.map { label + ", " + PaveFingerprint.spoken($0) }
            ?? PaveCopy.text("pave.fingerprint.unavailable"))
    }
}

extension PaveCameraAuthorization {
    static var current: PaveCameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
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
            PaveExchangeScreen(nickname: "Renard 42", myNoiseKey: Data(repeating: 7, count: 32),
                               makePayload: { "bitchat://verify?preview" },
                               contactName: "Nora", progress: PaveExchangeProgress(theyScannedMe: true, iScannedThem: false),
                               camera: .placeholder, onScan: { _ in }, onComplete: {}, onClose: {})
        }
        PavePreview.variants {
            PaveExchangeScreen(nickname: "Renard 42", myNoiseKey: Data(repeating: 7, count: 32),
                               makePayload: { "bitchat://verify?preview" },
                               contactName: "Nora", contactNoiseKey: Data(repeating: 9, count: 32),
                               progress: PaveExchangeProgress(theyScannedMe: true, iScannedThem: true),
                               camera: .placeholder, onScan: { _ in }, onComplete: {}, onClose: {})
        }
    }
}
