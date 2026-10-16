import SwiftUI

/// Where a conversation happens. Public is yellow, private is chalk or ink, never both.
enum PaveConversationKind: Equatable {
    case publicRoom
    case privateChat(contactName: String)
}

/// A bubble with its author's corner pulled in to `radius-tail`.
struct PaveBubbleShape: Shape {
    /// The tail sits bottom-trailing for your messages, bottom-leading for others.
    let tailTrailing: Bool

    func path(in rect: CGRect) -> Path {
        let big = min(PaveRadius.bubble, rect.height / 2, rect.width / 2)
        let tail = min(PaveRadius.tail, big)
        let bottomLeading = tailTrailing ? big : tail
        let bottomTrailing = tailTrailing ? tail : big
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + big, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - big, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + big), radius: big)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomTrailing))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - bottomTrailing, y: rect.maxY), radius: bottomTrailing)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeading, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bottomLeading), radius: bottomLeading)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + big))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + big, y: rect.minY), radius: big)
        path.closeSubpath()
        return path
    }
}

/// One message. Yours are filled, others are bordered, so they read apart in full sun.
struct PaveMessageBubble: View {
    let text: String
    let isOwn: Bool
    let kind: PaveConversationKind
    /// Shown above the first received message of a series.
    var senderName: String?
    let time: String
    /// Your messages only.
    var delivery: PaveDeliveryState?
    var transport: PaveTransport?
    var onRetry: (() -> Void)?
    /// Opens the delivery detail.
    var onShowDetail: (() -> Void)?

    @Environment(\.paveTheme) private var theme

    var body: some View {
        VStack(alignment: isOwn ? .trailing : .leading, spacing: PaveSpace.s1) {
            if !isOwn, let senderName {
                Text(senderName)
                    .paveText(.caption)
                    .foregroundStyle(theme[.inkMuted])
                    .padding(.leading, PaveSpace.s1)
                    .accessibilityHidden(true)
            }
            bubble
            meta
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    @ViewBuilder private var bubble: some View {
        if let onShowDetail {
            Button(action: onShowDetail) { bubbleContent }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
                .accessibilityHint(PaveCopy.text("pave.bubble.detailHint"))
                .accessibilityAddTraits(.isButton)
        } else {
            bubbleContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityText)
        }
    }

    private var bubbleContent: some View {
        let shape = PaveBubbleShape(tailTrailing: isOwn)
        return Text(text)
            .paveText(.body)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(PaveSpace.s3)
            .foregroundStyle(theme[textRole])
            .background(theme[fillRole], in: shape)
            .overlay(shape.stroke(isOwn ? .clear : theme[.lineStrong], lineWidth: PaveStroke.control))
            .contentShape(shape)
            .padding(isOwn ? .leading : .trailing, PaveSpace.s12)
    }

    @ViewBuilder private var meta: some View {
        if delivery == .failed, let onRetry {
            Button(action: onRetry) {
                Label(PaveCopy.text("pave.bubble.failedRetry"), systemImage: "exclamationmark.circle.fill")
                    .paveText(.caption)
                    .foregroundStyle(theme[.danger])
                    .frame(minHeight: PaveTouch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PaveCopy.text("pave.bubble.retryA11y"))
        } else {
            HStack(spacing: PaveSpace.s1) {
                Text(time).foregroundStyle(theme[.inkMuted])
                if let delivery {
                    Text(verbatim: "·").foregroundStyle(theme[.inkMuted])
                    Text(delivery.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(theme[PaveTheme.deliveryRole(delivery)])
                }
                if let transport {
                    Text(verbatim: "·").foregroundStyle(theme[.inkMuted])
                    Text(transport.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(transport == .internet ? theme[.internet] : theme[.inkMuted])
                }
            }
            .paveText(.caption)
            .padding(.horizontal, PaveSpace.s1)
            .accessibilityHidden(true)
        }
    }

    private var fillRole: PaveColorRole {
        guard isOwn else { return .surface }
        return kind == .publicRoom ? .publicFill : .privateFill
    }

    private var textRole: PaveColorRole {
        guard isOwn else { return .ink }
        return kind == .publicRoom ? .onPublic : .onPrivate
    }

    private var accessibilityText: String {
        let author = isOwn ? PaveCopy.text("pave.bubble.you") : (senderName ?? "")
        var parts = [author, text, time].filter { !$0.isEmpty }
        if let delivery { parts.append(delivery.label) }
        if let transport { parts.append(transport.label) }
        return parts.joined(separator: ", ")
    }
}

struct PaveMessageBubble_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            ScrollView {
                VStack(spacing: PaveSpace.s2) {
                    PaveMessageBubble(text: "On se retrouve devant la fontaine à 18 h ?", isOwn: false,
                                      kind: .privateChat(contactName: "Nora"), senderName: "Nora",
                                      time: "17:52", transport: .bluetooth)
                    PaveMessageBubble(text: "Oui, j'arrive par la rue de la Paix.", isOwn: true,
                                      kind: .privateChat(contactName: "Nora"), time: "17:53",
                                      delivery: .received, onShowDetail: {})
                    PaveMessageBubble(text: "Je suis là.", isOwn: true, kind: .privateChat(contactName: "Nora"),
                                      time: "17:59", delivery: PaveDeliveryState(.sent, isPrivate: true),
                                      transport: .internet)
                    PaveMessageBubble(text: "Tu me vois ?", isOwn: true, kind: .privateChat(contactName: "Nora"),
                                      time: "18:00", delivery: .failed, onRetry: {})
                    PaveMessageBubble(text: "Point d'eau ouvert au coin de la place.", isOwn: true,
                                      kind: .publicRoom, time: "18:01", delivery: .waiting)
                }
                .padding(PaveSpace.s4)
            }
        }
    }
}
