import SwiftUI

/// « Maintenir pour tout effacer »: a three-second hold fills a `danger` ring with rising pulses.
/// Releasing early cancels. Assistive technologies get a double tap and a one-line confirmation.
struct PaveHoldToErase: View {
    enum Layout {
        /// Ring above the text, for the erase screen.
        case stacked
        /// Ring beside the text inside a bordered card, for the first Settings row.
        case row
    }

    var layout: Layout = .stacked
    let onErase: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holdStart: Date?
    @State private var lastElapsed: TimeInterval = 0
    @State private var progress: Double = 0
    @State private var showsHoldHint = false
    @State private var confirming = false

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(spacing: PaveSpace.s3) {
                    ring(diameter: 112)
                    texts(alignment: .center)
                }
                .padding(.vertical, PaveSpace.s6)
            case .row:
                HStack(spacing: PaveSpace.s4) {
                    ring(diameter: 72)
                    texts(alignment: .leading)
                    Spacer(minLength: 0)
                }
                .padding(PaveSpace.s4)
                .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                    .strokeBorder(theme[.danger], lineWidth: PaveStroke.control))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PaveCopy.text("pave.erase.a11yLabel"))
        .accessibilityValue(holdStart == nil ? "" : "\(Int(progress * 100)) %")
        .accessibilityHint(PaveCopy.text("pave.erase.a11yHint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { confirming = true }
        .alert(PaveCopy.text("pave.erase.confirmTitle"), isPresented: $confirming) {
            Button(PaveCopy.text("pave.erase.confirmAction"), role: .destructive) { complete() }
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
        }
        .task(id: holdStart) { await runHold() }
    }

    private func ring(diameter: CGFloat) -> some View {
        let lineWidth = diameter / 14
        return ZStack {
            Circle().stroke(theme[.line], lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(theme[.danger], style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().fill(theme[.danger]).padding(diameter * 0.2)
            Image(systemName: "flame.fill")
                .font(.system(size: diameter * 0.26, weight: .semibold))
                .foregroundStyle(theme[.onDanger])
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard holdStart == nil else { return }
                    showsHoldHint = false
                    lastElapsed = 0
                    holdStart = Date()
                }
                .onEnded { _ in cancelHold() }
        )
    }

    private func texts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: PaveSpace.s1) {
            Text(PaveCopy.text("pave.erase.holdTitle"))
                .paveText(layout == .row ? .body : .label)
                .fontWeight(.bold)
                .foregroundStyle(theme[.danger])
            Text(PaveCopy.text(layout == .row ? "pave.erase.scopeShortcut" : "pave.erase.scope"))
                .paveText(.caption)
                .foregroundStyle(theme[.inkMuted])
            if showsHoldHint {
                Text(PaveCopy.text("pave.erase.holdHint"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.ink])
                    .transition(PaveMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runHold() async {
        guard let start = holdStart else { return }
        while !Task.isCancelled, holdStart == start {
            let elapsed = Date().timeIntervalSince(start)
            for intensity in PaveHoldSchedule.pulses(after: lastElapsed, upTo: elapsed) {
                PaveHaptics.play(.holdPulse(intensity: intensity))
            }
            lastElapsed = elapsed
            progress = PaveHoldSchedule.progress(elapsed: elapsed)
            if PaveHoldSchedule.isComplete(elapsed: elapsed) {
                holdStart = nil
                complete()
                return
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func cancelHold() {
        guard holdStart != nil else { return }
        holdStart = nil
        withAnimation(PaveMotion.animation(PaveMotion.stateChange, reduceMotion: reduceMotion)) {
            progress = 0
            showsHoldHint = true
        }
    }

    private func complete() {
        progress = 0
        PaveHaptics.play(.erase)
        onErase()
    }
}

/// The screen the « Tout effacer » shortcut opens. It never erases without the hold.
struct PaveEraseScreen: View {
    enum Outcome {
        case ready, erased, failed
    }

    /// Runs the local wipe; returns whether it completed.
    let erase: () -> Bool
    let onClose: () -> Void

    @Environment(\.paveTheme) private var theme
    @State private var outcome: Outcome

    init(outcome: Outcome = .ready, erase: @escaping () -> Bool, onClose: @escaping () -> Void) {
        _outcome = State(initialValue: outcome)
        self.erase = erase
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s4) {
            switch outcome {
            case .ready: ready
            case .erased: erased
            case .failed: failed
            }
        }
        .padding(.horizontal, PaveSpace.s4)
        .padding(.top, PaveSpace.s8)
        .padding(.bottom, PaveSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .paveScreenBackground()
    }

    private var ready: some View {
        Group {
            HStack {
                Text(PaveCopy.text("pave.erase.title")).paveText(.title).accessibilityAddTraits(.isHeader)
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
            ScrollView {
                VStack(spacing: PaveSpace.s4) {
                    PaveHoldToErase {
                        outcome = erase() ? .erased : .failed
                        if outcome == .failed { PaveHaptics.play(.failure) }
                    }
                    .padding(.vertical, PaveSpace.s12)
                    Text(PaveCopy.text("pave.erase.othersKeepCopies"))
                        .paveText(.caption)
                        .foregroundStyle(theme[.inkMuted])
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var erased: some View {
        Group {
            PaveWordmark()
            Text(PaveCopy.text("pave.erase.emptyTitle")).paveText(.title).accessibilityAddTraits(.isHeader)
            Text(PaveCopy.text("pave.erase.emptyBody")).paveText(.body)
            Text(PaveCopy.text("pave.erase.emptyContacts")).paveText(.body).foregroundStyle(theme[.inkMuted])
            Spacer()
            Button(PaveCopy.text("pave.erase.restart"), action: onClose).buttonStyle(.pavePrimary)
        }
    }

    private var failed: some View {
        Group {
            Label(PaveCopy.text("pave.erase.failedTitle"), systemImage: "exclamationmark.triangle.fill")
                .paveText(.title)
                .foregroundStyle(theme[.danger])
                .accessibilityAddTraits(.isHeader)
            Text(PaveCopy.text("pave.erase.failedBody")).paveText(.body)
            Spacer()
            Button(PaveCopy.text("pave.action.retry")) { outcome = .ready }.buttonStyle(.pavePrimary)
            Button(PaveCopy.text("pave.action.close"), action: onClose).buttonStyle(.paveSecondary)
        }
    }
}

struct PaveHoldToErase_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            VStack(spacing: PaveSpace.s6) {
                PaveHoldToErase(layout: .row) {}
                PaveHoldToErase {}
            }
            .padding(PaveSpace.s4)
        }
        PavePreview.variants {
            PaveEraseScreen(erase: { true }, onClose: {})
        }
        PavePreview.variants {
            PaveEraseScreen(outcome: .erased, erase: { true }, onClose: {})
        }
        PavePreview.variants {
            PaveEraseScreen(outcome: .failed, erase: { false }, onClose: {})
        }
    }
}
