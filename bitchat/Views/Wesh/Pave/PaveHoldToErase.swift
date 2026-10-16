import SwiftUI

/// « Maintenir pour tout effacer »: a three-second hold fills a `danger` ring with rising pulses.
/// The system long press owns press tracking and cancellation; `PaveHoldTracker` adds a
/// monotonic check, so the erase fails closed. Releasing early cancels. Assistive technologies
/// get a double tap and a one-line confirmation. Keep this view out of scrollable containers.
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
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var pressing = false
    @State private var tracker = PaveHoldTracker()
    @State private var holdID = 0
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
        .accessibilityValue(tracker.isHolding ? "\(Int(tracker.progress * 100)) %" : "")
        .accessibilityHint(PaveCopy.text("pave.erase.a11yHint"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { confirming = true }
        .alert(PaveCopy.text("pave.erase.confirmTitle"), isPresented: $confirming) {
            Button(PaveCopy.text("pave.erase.confirmAction"), role: .destructive) { complete() }
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
        }
        .onChange(of: pressing) { isPressing in
            if isPressing {
                showsHoldHint = false
                tracker.press(at: .now)
                holdID += 1
            } else {
                // After a completed erase the tracker is already idle: no hint then.
                let wasHolding = tracker.isHolding
                if !tracker.release(at: .now) { resetRing(showingHint: wasHolding) }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { resetRing(showingHint: false) }
        }
        .onDisappear { tracker.cancel() }
        .task(id: holdID) { await followHold() }
    }

    private func ring(diameter: CGFloat) -> some View {
        let lineWidth = diameter / 14
        return ZStack {
            Circle().stroke(theme[.line], lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: tracker.progress)
                .stroke(theme[.danger], style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().fill(theme[.danger]).padding(diameter * 0.2)
            Image(systemName: "flame.fill")
                .font(.system(size: diameter * 0.26, weight: .semibold))
                .foregroundStyle(theme[.onDanger])
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .highPriorityGesture(
            LongPressGesture(minimumDuration: PaveHoldSchedule.duration, maximumDistance: PaveTouch.minimum / 2)
                .updating($pressing) { isPressing, state, _ in state = isPressing }
                .onEnded { _ in
                    if tracker.confirm(at: .now) {
                        complete()
                    } else {
                        resetRing(showingHint: true)
                    }
                }
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

    /// Drives the ring and the pulses while the press lasts; never erases by itself.
    private func followHold() async {
        while !Task.isCancelled, tracker.isHolding {
            try? await Task.sleep(for: PaveHoldTracker.tickInterval)
            guard !Task.isCancelled else { return }
            for intensity in tracker.tick(at: .now) {
                PaveHaptics.play(.holdPulse(intensity: intensity))
            }
        }
    }

    private func resetRing(showingHint: Bool) {
        withAnimation(PaveMotion.animation(PaveMotion.stateChange, reduceMotion: reduceMotion)) {
            tracker.cancel()
            showsHoldHint = showingHint
        }
    }

    private func complete() {
        tracker.cancel()
        PaveHaptics.play(.erase)
        onErase()
    }
}

/// The screen the « Tout effacer » shortcut opens. It never erases without the hold.
struct PaveEraseScreen: View {
    enum Outcome {
        case ready, erased, failed

        init(erased: Bool) {
            self = erased ? .erased : .failed
        }
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
        Group {
            switch outcome {
            case .ready:
                // Not inside a ScrollView: a scroll must never compete with the hold.
                page { ready }
            case .erased:
                // These two scroll, so large Dynamic Type never pushes their buttons off screen.
                ScrollView { page { erased } }
            case .failed:
                ScrollView { page { failed } }
            }
        }
        .paveScreenBackground()
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PaveSpace.s4) { content() }
            .padding(.horizontal, PaveSpace.s4)
            .padding(.top, PaveSpace.s8)
            .padding(.bottom, PaveSpace.s6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Spacer(minLength: 0)
            // Not inside a ScrollView: a scroll must never compete with the hold.
            VStack(spacing: PaveSpace.s4) {
                PaveHoldToErase {
                    outcome = Outcome(erased: erase())
                    if outcome == .failed { PaveHaptics.play(.failure) }
                }
                .padding(.vertical, PaveSpace.s12)
                Text(PaveCopy.text("pave.erase.othersKeepCopies"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    private var erased: some View {
        Group {
            PaveWordmark()
            Text(PaveCopy.text("pave.erase.emptyTitle")).paveText(.title).accessibilityAddTraits(.isHeader)
            Text(PaveCopy.text("pave.erase.emptyBody")).paveText(.body)
            Text(PaveCopy.text("pave.erase.emptyContacts")).paveText(.body).foregroundStyle(theme[.inkMuted])
            Spacer(minLength: PaveSpace.s6)
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
            Spacer(minLength: PaveSpace.s6)
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
