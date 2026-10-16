import SwiftUI

/// The three kinds of rows in Discussions. No destructive action lives in a row.
enum PaveInboxItem {
    /// The public room card, always first.
    case publicRoom(inRange: Int, lastMessage: String?, time: String?)
    /// A verified contact; the preview is the last message, never a status line.
    /// `fingerprint` is `PaveFingerprint.short(_:)` of the contact's Noise static key, nil when
    /// unknown; it has no default, so no row shows a remote name without it.
    case contact(name: String, fingerprint: String?, lastMessage: String?, time: String?)
    /// An unverified request; its content stays hidden until codes are exchanged.
    case request(name: String, fingerprint: String?, messageCount: Int, time: String)
}

struct PaveInboxRow: View {
    let item: PaveInboxItem
    let action: () -> Void
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Button(action: action) {
            switch item {
            case let .publicRoom(inRange, lastMessage, time):
                publicCard(inRange: inRange, lastMessage: lastMessage, time: time)
            case let .contact(name, fingerprint, lastMessage, time):
                row(name: name, fingerprint: fingerprint, verified: true,
                    preview: Text(lastMessage ?? PaveCopy.text("pave.inbox.noMessage")), time: time)
            case let .request(name, fingerprint, count, time):
                row(name: name, fingerprint: fingerprint, verified: false,
                    preview: Text(PaveCopy.text("pave.inbox.unverified")).foregroundColor(theme[.warning])
                        + Text(verbatim: " · ")
                        + Text(PaveCopy.text("pave.inbox.requestPreview", count)),
                    time: time)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hint)
    }

    /// Spoken in a fixed order, the trust state before the peer-chosen name and its fingerprint.
    private var accessibilityText: String {
        switch item {
        case let .publicRoom(inRange, lastMessage, time):
            return [PaveCopy.text("pave.inbox.publicTitle"), PaveCopy.text("pave.inbox.publicInRange", inRange),
                    lastMessage, time].compactMap { $0 }.joined(separator: ", ")
        case let .contact(name, fingerprint, lastMessage, time):
            return [PaveCopy.text("pave.inbox.verified"), PaveDisplayName.safe(name),
                    PaveFingerprint.accessibilityText(fingerprint),
                    lastMessage ?? PaveCopy.text("pave.inbox.noMessage"), time].compactMap { $0 }.joined(separator: ", ")
        case let .request(name, fingerprint, count, time):
            return [PaveCopy.text("pave.inbox.unverified"), PaveDisplayName.safe(name),
                    PaveFingerprint.accessibilityText(fingerprint),
                    PaveCopy.text("pave.inbox.requestPreview", count), time].joined(separator: ", ")
        }
    }

    private var hint: String {
        switch item {
        case .publicRoom: return PaveCopy.text("pave.inbox.publicHint")
        case .contact: return PaveCopy.text("pave.inbox.contactHint")
        case .request: return PaveCopy.text("pave.inbox.requestHint")
        }
    }

    private func publicCard(inRange: Int, lastMessage: String?, time: String?) -> some View {
        VStack(alignment: .leading, spacing: PaveSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: PaveSpace.s2) {
                Label(PaveCopy.text("pave.inbox.publicTitle"), systemImage: "megaphone.fill")
                    .paveText(.headline)
                Spacer(minLength: PaveSpace.s2)
                Text(PaveCopy.text("pave.inbox.publicInRange", inRange))
                    .paveText(.caption)
            }
            if let lastMessage {
                Text(lastMessage).paveText(.body).lineLimit(2)
            }
            Text(time.map { PaveCopy.text("pave.inbox.publicFootnoteTime", $0) } ?? PaveCopy.text("pave.inbox.publicFootnote"))
                .paveText(.caption)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(theme[.onPublic])
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(PaveSpace.s4)
        .background(theme[.publicFill], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }

    /// The trust badge is a fixed-size symbol in a fixed leading column: the name, whatever
    /// its content or length, can neither move it nor sit where it sits.
    private func row(name: String, fingerprint: String?, verified: Bool, preview: Text, time: String?) -> some View {
        HStack(alignment: .top, spacing: PaveSpace.s3) {
            trustBadge(verified: verified)
            VStack(alignment: .leading, spacing: PaveSpace.s1) {
                HStack(alignment: .firstTextBaseline, spacing: PaveSpace.s3) {
                    Text(PaveDisplayName.safe(name))
                        .paveText(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let time {
                        Text(time).paveText(.caption).foregroundStyle(theme[.inkMuted]).fixedSize()
                    }
                }
                PaveFingerprintText(fingerprint: fingerprint)
                preview
                    .paveText(verified ? .body : .label)
                    .foregroundStyle(theme[.inkMuted])
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(theme[.ink])
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, PaveSpace.s4)
        .padding(.vertical, PaveSpace.s3)
        .background(verified ? theme[.surface] : .clear, in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
            .strokeBorder(verified ? .clear : theme[.lineStrong], lineWidth: PaveStroke.control))
        .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }

    private func trustBadge(verified: Bool) -> some View {
        Image(systemName: verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(verified ? theme[.success] : theme[.warning])
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

struct PaveInboxRow_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            ScrollView {
                VStack(spacing: PaveSpace.s2) {
                    PaveInboxRow(item: .publicRoom(inRange: 7, lastMessage: "Point d'eau ouvert au coin de la place.",
                                                   time: "18:01")) {}
                    PaveInboxRow(item: .contact(name: "Nora", fingerprint: "7F3A 91C2 0B5E 44D8",
                                                lastMessage: "Oui, j'arrive par la rue de la Paix.", time: "17:53")) {}
                    PaveInboxRow(item: .contact(name: "Sami", fingerprint: nil, lastMessage: nil, time: nil)) {}
                    PaveInboxRow(item: .request(name: "Léo 17", fingerprint: "0B5E 44D8 7F3A 91C2",
                                                messageCount: 1, time: "18:02")) {}
                    // A hostile nickname: bidi override, fake badge text, a newline and a long tail.
                    PaveInboxRow(item: .request(name: "\u{202E}Nora ✓ Vérifié\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
                                                fingerprint: "A1B2 C3D4 E5F6 0718", messageCount: 2, time: "18:05")) {}
                }
                .padding(PaveSpace.s4)
            }
        }
    }
}
