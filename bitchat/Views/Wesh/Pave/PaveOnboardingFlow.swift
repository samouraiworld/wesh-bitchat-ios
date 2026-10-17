import SwiftUI

/// Bienvenue, then the Bluetooth explainer shown before the system prompt.
struct PaveOnboardingFlow: View {
    enum Step {
        case welcome, bluetooth
    }

    static let termsURL = URL(string: "https://wesh.samourai.app/conditions")

    /// Triggers the system Bluetooth prompt.
    let onRequestBluetooth: () -> Void
    /// Receives the chosen nickname once onboarding ends.
    let onFinish: (String) -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step
    @State private var nickname: String

    init(step: Step = .welcome, nickname: String? = nil,
         onRequestBluetooth: @escaping () -> Void, onFinish: @escaping (String) -> Void) {
        var generator = SystemRandomNumberGenerator()
        _step = State(initialValue: step)
        _nickname = State(initialValue: nickname ?? PaveNicknameGenerator().make(using: &generator))
        self.onRequestBluetooth = onRequestBluetooth
        self.onFinish = onFinish
    }

    private var trimmedNickname: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nicknameIsValid: Bool { !trimmedNickname.isEmpty && trimmedNickname.utf8.count <= 255 }

    var body: some View {
        ScrollView {
            Group {
                switch step {
                case .welcome: welcome
                case .bluetooth: bluetooth
                }
            }
            .padding(.horizontal, PaveSpace.s6)
            .padding(.top, PaveSpace.s12)
            .padding(.bottom, PaveSpace.s8)
            .transition(PaveMotion.transition(reduceMotion: reduceMotion))
        }
        .paveScreenBackground()
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s8) {
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                HStack(alignment: .bottom, spacing: PaveSpace.s2) {
                    RoundedRectangle(cornerRadius: PaveRadius.control).fill(theme[.publicFill])
                        .frame(width: PaveSpace.s12, height: PaveSpace.s12)
                    RoundedRectangle(cornerRadius: PaveRadius.control / 2).fill(theme[.privateFill])
                        .frame(width: PaveSpace.s6, height: PaveSpace.s6)
                }
                .accessibilityHidden(true)
                PaveWordmark(baseSize: 72)
                Text(PaveCopy.text("pave.onboarding.tagline"))
                    .paveText(.headline)
            }
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                bullet("pave.onboarding.noAccount", role: .success)
                bullet("pave.onboarding.publicRoom", role: .publicFill)
                bullet("pave.onboarding.privateByQR", role: .privateFill)
            }
            VStack(alignment: .leading, spacing: PaveSpace.s2) {
                Text(PaveCopy.text("pave.onboarding.nicknameLabel"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                HStack(spacing: PaveSpace.s2) {
                    TextField(PaveCopy.text("pave.onboarding.nicknameLabel"), text: $nickname)
                        .paveText(.body)
                        .autocorrectionDisabled()
                        .padding(.horizontal, PaveSpace.s4)
                        .frame(minHeight: PaveTouch.primary)
                        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
                        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                            .strokeBorder(theme[.lineStrong], lineWidth: PaveStroke.control))
                        .accessibilityLabel(PaveCopy.text("pave.onboarding.nicknameLabel"))
                    Button {
                        var generator = SystemRandomNumberGenerator()
                        nickname = PaveNicknameGenerator().make(differentFrom: nickname, using: &generator)
                    } label: {
                        Image(systemName: "shuffle")
                            .font(PaveTextStyle.headline.font)
                            .frame(width: PaveTouch.primary, height: PaveTouch.primary)
                            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                                .strokeBorder(theme[.lineStrong], lineWidth: PaveStroke.control))
                            .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PaveCopy.text("pave.onboarding.shuffle"))
                }
                Text(PaveCopy.text("pave.onboarding.nicknameHelp"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
            }
            VStack(spacing: PaveSpace.s2) {
                Button(PaveCopy.text("pave.action.start")) { advance(to: .bluetooth) }
                    .buttonStyle(.pavePrimary)
                    .disabled(!nicknameIsValid)
                Text(PaveCopy.text("pave.onboarding.terms"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                    .multilineTextAlignment(.center)
                if let termsURL = Self.termsURL {
                    Link(destination: termsURL) {
                        Text(PaveCopy.text("pave.onboarding.readTerms"))
                            .paveText(.caption)
                            .underline()
                            .frame(minHeight: PaveTouch.minimum)
                    }
                    .foregroundStyle(theme[.ink])
                }
            }
        }
    }

    private var bluetooth: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(theme[.ink])
                .accessibilityHidden(true)
            Text(PaveCopy.text("pave.onboarding.bluetoothTitle"))
                .paveText(.title)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                Text(PaveCopy.text("pave.onboarding.bluetoothWhy")).paveText(.body)
                Text(PaveCopy.text("pave.onboarding.bluetoothPrompt")).paveText(.body)
                Text(PaveCopy.text("pave.onboarding.noLocation")).paveText(.body)
            }
            Label(PaveCopy.text("pave.connexion.visibility"), systemImage: "exclamationmark.triangle.fill")
                .paveText(.caption)
                .foregroundStyle(theme[.ink])
                .padding(PaveSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                    .strokeBorder(theme[.warning], lineWidth: PaveStroke.control))
            VStack(spacing: PaveSpace.s3) {
                Button(PaveCopy.text("pave.onboarding.allowBluetooth")) {
                    onRequestBluetooth()
                    onFinish(trimmedNickname)
                }
                .buttonStyle(.pavePrimary)
            }
        }
    }

    private func bullet(_ key: String, role: PaveColorRole) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PaveSpace.s3) {
            Circle().fill(theme[role])
                .overlay(Circle().strokeBorder(theme[.lineStrong], lineWidth: PaveStroke.hairline))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(PaveCopy.text(key))
                .paveText(.label)
                .fontWeight(.regular)
                .foregroundStyle(theme[.inkMuted])
        }
    }

    private func advance(to next: Step) {
        withAnimation(PaveMotion.animation(PaveMotion.sheet, reduceMotion: reduceMotion)) { step = next }
    }
}

struct PaveOnboardingFlow_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            PaveOnboardingFlow(nickname: "Renard 42", onRequestBluetooth: {}, onFinish: { _ in })
        }
        PavePreview.variants {
            PaveOnboardingFlow(step: .bluetooth, nickname: "Renard 42", onRequestBluetooth: {}, onFinish: { _ in })
        }
    }
}
