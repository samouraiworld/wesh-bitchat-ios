import SwiftUI

/// The Settings rows, in mockup order. The erase card always comes first.
enum PaveSettingsDestination: CaseIterable, Identifiable {
    case profile, connexion, discretion, meetingPoint, blocked, appearance, about
    var id: Self { self }

    var title: String {
        switch self {
        case .profile: return PaveCopy.text("pave.settings.profile")
        case .connexion: return PaveCopy.text("pave.connexion.title")
        case .discretion: return PaveCopy.text("pave.settings.discretion")
        case .meetingPoint: return PaveCopy.text("pave.settings.meetingPoint")
        case .blocked: return PaveCopy.text("pave.settings.blocked")
        case .appearance: return PaveCopy.text("pave.settings.appearance")
        case .about: return PaveCopy.text("pave.settings.about")
        }
    }
}

/// What the Settings rows summarize on their trailing side.
struct PaveSettingsSummary {
    var nickname: String
    var previewsHidden: Bool
    var meetingNote: String?
    var blockedCount: Int
    var theme: PaveThemeID

    func value(for destination: PaveSettingsDestination) -> String {
        switch destination {
        case .profile: return nickname
        case .connexion: return PaveCopy.text("pave.settings.connexionValue")
        case .discretion:
            return PaveCopy.text(previewsHidden ? "pave.settings.previewsHidden" : "pave.settings.previewsShown")
        case .meetingPoint:
            return meetingNote.flatMap { $0.isEmpty ? nil : $0 } ?? PaveCopy.text("pave.settings.meetingNone")
        case .blocked: return blockedCount.formatted()
        case .appearance: return PaveCopy.text(theme == .nuit ? "pave.theme.nuit" : "pave.theme.jour")
        case .about: return PaveCopy.text("pave.settings.aboutValue")
        }
    }
}

struct PaveSettingsScreen: View {
    let summary: PaveSettingsSummary
    let onErase: () -> Void
    let onSelect: (PaveSettingsDestination) -> Void

    @Environment(\.paveTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s3) {
                Text(PaveCopy.text("pave.settings.title"))
                    .paveText(.title)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, PaveSpace.s1)
                PaveHoldToErase(layout: .row, onErase: onErase)
                VStack(spacing: 0) {
                    ForEach(PaveSettingsDestination.allCases) { destination in
                        row(destination)
                        if destination != PaveSettingsDestination.allCases.last {
                            Rectangle().fill(theme[.line]).frame(height: PaveStroke.hairline)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
                Text(PaveCopy.text("pave.settings.footer"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, PaveSpace.s6)
            }
            .padding(.horizontal, PaveSpace.s4)
            .padding(.top, PaveSpace.s4)
            .padding(.bottom, PaveSpace.s6)
        }
        .paveScreenBackground()
    }

    private func row(_ destination: PaveSettingsDestination) -> some View {
        Button { onSelect(destination) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PaveSpace.s3) {
                    Text(destination.title).paveText(.body)
                    Spacer(minLength: PaveSpace.s2)
                    trailing(destination)
                }
                VStack(alignment: .leading, spacing: PaveSpace.s1) {
                    Text(destination.title).paveText(.body)
                    trailing(destination)
                }
            }
            .foregroundStyle(theme[.ink])
            .padding(.horizontal, PaveSpace.s4)
            .padding(.vertical, PaveSpace.s2)
            .frame(maxWidth: .infinity, minHeight: PaveTouch.primary, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func trailing(_ destination: PaveSettingsDestination) -> some View {
        HStack(spacing: PaveSpace.s1) {
            Text(summary.value(for: destination))
                .paveText(.label)
                .fontWeight(.regular)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(PaveTextStyle.caption.font)
                .accessibilityHidden(true)
        }
        .foregroundStyle(theme[.inkMuted])
    }
}

/// À propos: what Wesh is, where its code lives, and how to support it.
struct PaveAboutScreen: View {
    static let sourceURL = URL(string: "https://github.com/samouraiworld/wesh-bitchat-ios")
    static let donationsURL = URL(string: "https://wesh.samourai.app/dons")

    let version: String
    @Environment(\.paveTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s6) {
                VStack(alignment: .leading, spacing: PaveSpace.s2) {
                    PaveWordmark()
                    Text(PaveCopy.text("pave.about.tagline")).paveText(.body)
                    Text(PaveCopy.text("pave.about.version", version))
                        .paveText(.caption)
                        .foregroundStyle(theme[.inkMuted])
                }
                VStack(spacing: PaveSpace.s3) {
                    if let sourceURL = Self.sourceURL {
                        Link(destination: sourceURL) { Text(PaveCopy.text("pave.about.source")) }
                            .buttonStyle(.paveSecondary)
                    }
                    if let donationsURL = Self.donationsURL {
                        Link(destination: donationsURL) { Text(PaveCopy.text("pave.about.donate")) }
                            .buttonStyle(.paveSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: PaveSpace.s2) {
                    Text(PaveCopy.text("pave.about.licensesTitle"))
                        .paveText(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(PaveCopy.text("pave.about.licenseWesh")).paveText(.body)
                    Text(PaveCopy.text("pave.about.licenseThirdParty"))
                        .paveText(.label)
                        .fontWeight(.regular)
                        .foregroundStyle(theme[.inkMuted])
                }
                Text(PaveCopy.text("pave.settings.footer"))
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
            }
            .padding(PaveSpace.s4)
        }
        .paveScreenBackground()
    }
}

struct PaveSettingsScreen_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            PaveSettingsScreen(summary: PaveSettingsSummary(nickname: "Renard 42", previewsHidden: true,
                                                            meetingNote: "Fontaine, 18 h", blockedCount: 2,
                                                            theme: .nuit),
                               onErase: {}, onSelect: { _ in })
        }
        PavePreview.variants {
            PaveAboutScreen(version: "1.0 (1)")
        }
    }
}
