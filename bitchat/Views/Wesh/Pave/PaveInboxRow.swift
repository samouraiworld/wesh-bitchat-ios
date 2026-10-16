import SwiftUI

/// The three kinds of rows in Discussions. No destructive action lives in a row.
enum PaveInboxItem {
    /// The public room card, always first.
    case publicRoom(inRange: Int, lastMessage: String?, time: String?)
    /// A verified contact; the preview is the last message, never a status line.
    case contact(name: String, lastMessage: String?, time: String?)
    /// An unverified request; its content stays hidden until codes are exchanged.
    case request(name: String, messageCount: Int, time: String)
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
            case let .contact(name, lastMessage, time):
                row(name: name, badge: verifiedBadge, preview: lastMessage ?? PaveCopy.text("pave.inbox.noMessage"),
                    time: time, bordered: false)
            case let .request(name, count, time):
                row(name: name, badge: unverifiedBadge, preview: PaveCopy.text("pave.inbox.requestPreview", count),
                    time: time, bordered: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
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

    private func row(name: String, badge: some View, preview: String, time: String?, bordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: PaveSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: PaveSpace.s3) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: PaveSpace.s2) {
                        Text(name).paveText(.headline)
                        badge
                    }
                    VStack(alignment: .leading, spacing: PaveSpace.s1) {
                        Text(name).paveText(.headline)
                        badge
                    }
                }
                Spacer(minLength: 0)
                if let time {
                    Text(time).paveText(.caption).foregroundStyle(theme[.inkMuted])
                }
            }
            Text(preview)
                .paveText(bordered ? .label : .body)
                .foregroundStyle(theme[.inkMuted])
                .lineLimit(1)
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(theme[.ink])
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.horizontal, PaveSpace.s4)
        .padding(.vertical, PaveSpace.s3)
        .background(bordered ? .clear : theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
            .strokeBorder(bordered ? theme[.lineStrong] : .clear, lineWidth: PaveStroke.control))
        .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
    }

    private var verifiedBadge: some View {
        Label(PaveCopy.text("pave.inbox.verified"), systemImage: "checkmark.seal.fill")
            .paveText(.caption)
            .foregroundStyle(theme[.success])
    }

    private var unverifiedBadge: some View {
        Label(PaveCopy.text("pave.inbox.unverified"), systemImage: "exclamationmark.triangle.fill")
            .paveText(.caption)
            .foregroundStyle(theme[.warning])
    }
}

struct PaveInboxRow_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            ScrollView {
                VStack(spacing: PaveSpace.s2) {
                    PaveInboxRow(item: .publicRoom(inRange: 7, lastMessage: "Point d'eau ouvert au coin de la place.",
                                                   time: "18:01")) {}
                    PaveInboxRow(item: .contact(name: "Nora", lastMessage: "Oui, j'arrive par la rue de la Paix.",
                                                time: "17:53")) {}
                    PaveInboxRow(item: .contact(name: "Sami", lastMessage: nil, time: nil)) {}
                    PaveInboxRow(item: .request(name: "Léo 17", messageCount: 1, time: "18:02")) {}
                }
                .padding(PaveSpace.s4)
            }
        }
    }
}
