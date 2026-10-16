import SwiftUI

/// The message field. It carries the context color so nobody posts publicly by mistake.
struct PaveComposer: View {
    let kind: PaveConversationKind
    @Binding var text: String
    let onSend: () -> Void

    @Environment(\.paveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var budget: PaveMessageBudget { PaveMessageBudget(text) }
    private var canSend: Bool { PaveMessageBudget.canSend(text) }
    private var isPublic: Bool { kind == .publicRoom }

    var body: some View {
        VStack(alignment: .leading, spacing: PaveSpace.s1) {
            if budget.showsCounter {
                counter.transition(PaveMotion.transition(reduceMotion: reduceMotion))
            }
            HStack(alignment: .bottom, spacing: PaveSpace.s2) {
                Image(systemName: isPublic ? "megaphone.fill" : "lock.fill")
                    .font(PaveTextStyle.label.font)
                    .foregroundStyle(theme[.inkMuted])
                    .frame(minWidth: 28, minHeight: PaveTouch.primary)
                    .accessibilityHidden(true)
                TextField(placeholder, text: $text, axis: .vertical)
                    .paveText(.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .frame(minHeight: PaveTouch.minimum)
                    .padding(.vertical, PaveSpace.s1)
                    .accessibilityLabel(placeholder)
                sendButton
            }
            .padding(PaveSpace.s2)
            .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
            .overlay(RoundedRectangle(cornerRadius: PaveRadius.control)
                .strokeBorder(focused ? theme[.focus] : theme[.lineStrong],
                              lineWidth: focused ? PaveStroke.focus : PaveStroke.control))
        }
        .padding(.horizontal, PaveSpace.s4)
        .padding(.top, PaveSpace.s2)
        .padding(.bottom, PaveSpace.s2)
        .background(alignment: .top) {
            if isPublic {
                // The public composer's 3 pt top rule.
                Rectangle().fill(theme[.publicFill]).frame(height: PaveStroke.focus)
            }
        }
        .background(theme[.bg])
        .animation(PaveMotion.animation(PaveMotion.stateChange, reduceMotion: reduceMotion), value: budget.showsCounter)
    }

    private var placeholder: String {
        switch kind {
        case .publicRoom: return PaveCopy.text("pave.composer.publicPlaceholder")
        case .privateChat(let name): return PaveCopy.text("pave.composer.privatePlaceholder", name)
        }
    }

    private var sendLabel: String {
        switch kind {
        case .publicRoom: return PaveCopy.text("pave.composer.sendPublic")
        case .privateChat(let name): return PaveCopy.text("pave.composer.sendPrivate", name)
        }
    }

    private var sendButton: some View {
        Button {
            guard canSend else { return }
            PaveHaptics.play(.send)
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(PaveTextStyle.headline.font)
                .frame(width: PaveTouch.primary, height: PaveTouch.primary)
                .foregroundStyle(canSend ? theme[isPublic ? .onPublic : .onPrivate] : theme[.inkMuted])
                .background(canSend ? theme[isPublic ? .publicFill : .privateFill] : theme[.surfaceRaised],
                            in: RoundedRectangle(cornerRadius: PaveRadius.control))
                .contentShape(RoundedRectangle(cornerRadius: PaveRadius.control))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel(sendLabel)
    }

    private var counter: some View {
        let used = budget.usedBytes.formatted()
        let maximum = PaveMessageBudget.maximumBytes.formatted()
        let key = budget.isOverLimit ? "pave.composer.counterOver" : "pave.composer.counter"
        return Label {
            Text(PaveCopy.text(key, used, maximum))
        } icon: {
            Image(systemName: budget.isOverLimit ? "exclamationmark.circle.fill" : "text.alignleft")
        }
        .paveText(.caption)
        .foregroundStyle(budget.isOverLimit ? theme[.danger] : theme[.inkMuted])
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct PaveComposer_Previews: PreviewProvider {
    static var previews: some View {
        PavePreview.variants {
            VStack(spacing: PaveSpace.s6) {
                Spacer()
                PaveComposer(kind: .publicRoom, text: .constant(""), onSend: {})
                PaveComposer(kind: .privateChat(contactName: "Nora"), text: .constant("Je suis là."), onSend: {})
                PaveComposer(kind: .privateChat(contactName: "Nora"),
                             text: .constant(String(repeating: "a", count: 1850)), onSend: {})
                PaveComposer(kind: .publicRoom, text: .constant(String(repeating: "é", count: 1050)), onSend: {})
            }
        }
    }
}
