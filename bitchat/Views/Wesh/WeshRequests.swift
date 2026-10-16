import BitFoundation
import Combine
import Foundation
import SwiftUI

/// Public pages referenced from the app. One place, so a domain change is one line.
enum WeshLinks {
    static let terms = URL(string: "https://wesh.samourai.app/conditions")!
}

/// Inbound media from BitChat peers is never written to disk in Wesh.
/// Read from BLE queues, so it is a lock-guarded flag rather than MainActor state.
/// Fails closed: only tests that exercise upstream media opt in.
enum WeshIncomingMediaPolicy {
    private static let lock = NSLock()
    private static var _acceptsMedia = false

    static var acceptsMedia: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _acceptsMedia }
        set { lock.lock(); _acceptsMedia = newValue; lock.unlock() }
    }

    static let placeholder = "Média non pris en charge"

    /// Media references kept by older builds render as the same placeholder.
    static func displayText(_ content: String) -> String {
        let prefixes = [MimeType.Category.audio, .image, .file].map(\.messagePrefix)
        return prefixes.contains(where: { content.hasPrefix($0) }) ? placeholder : content
    }
}

/// Messages from senders who are not QR-verified contacts. RAM only, bounded,
/// never notified or acknowledged. They can be read, verified, blocked or deleted.
@MainActor
final class WeshInboundRequests: ObservableObject {
    static let shared = WeshInboundRequests()
    static let maxRequests = 20
    static let maxMessagesPerRequest = 20
    /// A full list makes room only by dropping a request shown this long.
    static let minimumDisplayAge: TimeInterval = 10 * 60
    /// A deleted message stays deleted when its sender retries it.
    static let deletedMemory: TimeInterval = 24 * 60 * 60
    static let maxDeletedMessages = 500

    struct Request: Identifiable {
        let noiseKey: Data
        var nickname: String
        var messages: [BitchatMessage]
        let receivedAt: Date
        var id: String { noiseKey.sha256Fingerprint() }
        var peerID: PeerID { PeerID(hexData: noiseKey) }
    }

    @Published private(set) var requests: [Request] = []
    private let now: () -> Date
    /// "fingerprint|messageID" of deleted request messages, with the deletion time.
    private var deleted: [String: Date] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Returns false when the message was dropped (duplicate or over capacity).
    @discardableResult
    func add(_ message: BitchatMessage, from noiseKey: Data) -> Bool {
        guard noiseKey.count == 32 else { return false }
        let fingerprint = noiseKey.sha256Fingerprint()
        let date = now()
        deleted = deleted.filter { date.timeIntervalSince($0.value) < Self.deletedMemory }
        guard deleted[fingerprint + "|" + message.id] == nil else { return false }
        let shown = BitchatMessage(
            id: message.id, sender: message.sender,
            content: WeshIncomingMediaPolicy.displayText(message.content),
            timestamp: message.timestamp, isRelay: false, originalSender: nil, isPrivate: true,
            recipientNickname: message.recipientNickname, senderPeerID: PeerID(hexData: noiseKey)
        )
        if let index = requests.firstIndex(where: { $0.id == fingerprint }) {
            guard !requests[index].messages.contains(where: { $0.id == message.id }) else { return false }
            requests[index].nickname = message.sender
            requests[index].messages.append(shown)
            if requests[index].messages.count > Self.maxMessagesPerRequest {
                requests[index].messages.removeFirst(requests[index].messages.count - Self.maxMessagesPerRequest)
            }
            return true
        }
        if requests.count >= Self.maxRequests {
            // New senders are not silently lost: the oldest request goes once it was shown long enough.
            guard let oldest = requests.indices
                .filter({ date.timeIntervalSince(requests[$0].receivedAt) >= Self.minimumDisplayAge })
                .min(by: { requests[$0].receivedAt < requests[$1].receivedAt }) else { return false }
            requests.remove(at: oldest)
        }
        requests.append(Request(noiseKey: noiseKey, nickname: message.sender, messages: [shown], receivedAt: date))
        return true
    }

    func remove(_ id: Request.ID) {
        let date = now()
        for request in requests where request.id == id {
            for message in request.messages { deleted[id + "|" + message.id] = date }
        }
        if deleted.count > Self.maxDeletedMessages {
            for entry in deleted.sorted(by: { $0.value < $1.value }).prefix(deleted.count - Self.maxDeletedMessages) {
                deleted.removeValue(forKey: entry.key)
            }
        }
        requests.removeAll { $0.id == id }
    }

    func clear() {
        requests = []
        deleted = [:]
    }
}

extension WeshMessageActions {
    /// Public mesh senders use a short ID derived from their Noise key. Only a
    /// known key whose derived ID matches exactly may be reported or blocked.
    static func publicAuthor(of sender: PeerID?, knownNoiseKeys: [Data]) -> PeerID? {
        guard let sender else { return nil }
        if let key = sender.noiseKey, key.count == 32 { return sender }
        guard sender.id.count == 16 else { return nil }
        let matches = knownNoiseKeys.filter { $0.count == 32 && PeerID(publicKey: $0) == sender }
        guard matches.count == 1, let key = matches.first else { return nil }
        return PeerID(hexData: key)
    }
}

extension ChatViewModel {
    /// Wesh admits private messages only from QR-verified contacts; anything
    /// else becomes a request, without notification or receipt.
    @MainActor
    func divertUnverifiedPrivateMessage(_ message: BitchatMessage, from peerID: PeerID) -> Bool {
        guard weshPrivatePolicyEnabled else { return false }
        guard let key = weshSenderKey(peerID) else { return true } // unidentifiable: drop
        let fingerprint = key.sha256Fingerprint()
        if isWeshEnrolled(fingerprint) { return false }
        if identityManager.isBlocked(fingerprint: fingerprint) { return true }
        WeshInboundRequests.shared.add(message, from: key)
        return true
    }

    /// Private traffic other than a plain message (favorite markers, Nostr
    /// DMs) is admitted only from a QR-verified contact, else dropped.
    @MainActor
    func admitsPrivateSender(_ peerID: PeerID) -> Bool {
        guard weshPrivatePolicyEnabled else { return true }
        guard let key = weshSenderKey(peerID) else { return false }
        return isWeshEnrolled(key.sha256Fingerprint())
    }

    @MainActor
    private func weshSenderKey(_ peerID: PeerID) -> Data? {
        let key = peerID.noiseKey ?? noiseSessionPublicKeyData(for: getShortIDForNoiseKey(peerID))
        return key?.count == 32 ? key : nil
    }

    @MainActor
    private func isWeshEnrolled(_ fingerprint: String) -> Bool {
        WeshQRTrust.shared.fingerprints.contains(fingerprint) && peerIdentityStore.isVerified(fingerprint)
    }

    /// Reporting stays on this phone: it blocks the author and removes their
    /// public messages from this timeline. Nothing is sent anywhere.
    @MainActor @discardableResult
    func reportWeshPublicAuthor(_ author: PeerID, displayName: String) -> Bool {
        guard let key = author.noiseKey, key.count == 32 else { return false }
        blockMeshPeer(peerID: author, displayName: displayName)
        guard identityManager.isBlocked(fingerprint: key.sha256Fingerprint()) else { return false }
        let shortID = PeerID(publicKey: key)
        conversations.removeMessages(from: .mesh) { message in
            message.senderPeerID == shortID || message.senderPeerID == author
        }
        return true
    }
}

/// Confirmation, then outcome, for a local report. Kept out of the
/// conversation body so its builder stays cheap to type-check.
struct WeshReportAlerts: ViewModifier {
    @Binding var target: PeerID?
    let name: String
    @Binding var done: Bool
    let report: (PeerID, String) -> Bool

    func body(content: Content) -> some View {
        content
            .alert("Signaler ce message ?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                Button("Annuler", role: .cancel) { target = nil }
                Button("Signaler et bloquer", role: .destructive) {
                    if let target { done = report(target, name) }
                    target = nil
                }
            } message: {
                Text("Le signalement reste sur ce téléphone : rien n’est envoyé. \(name) sera bloqué ici et ses messages seront masqués.")
            }
            .alert("Signalement enregistré", isPresented: $done) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Cette personne est bloquée sur ce téléphone et ses messages sont masqués. Vous pourrez la débloquer dans Réglages → Contacts bloqués.")
            }
    }
}

struct WeshRequestsSection: View {
    let runtime: AppRuntime
    @ObservedObject private var requests = WeshInboundRequests.shared
    @Environment(\.weshTheme) private var theme

    init(runtime: AppRuntime) { self.runtime = runtime }

    var body: some View {
        if !requests.requests.isEmpty {
            Section {
                ForEach(requests.requests) { request in
                    NavigationLink { WeshRequestDetail(runtime: runtime, requestID: request.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(request.nickname).font(.headline)
                            Text("Non vérifié · \(request.messages.count) message\(request.messages.count > 1 ? "s" : "")")
                                .font(.subheadline).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 8)
                    }
                    .accessibilityLabel("Demande de \(request.nickname), non vérifiée")
                }
            } header: { WeshSectionLabel(text: "Demandes") } footer: {
                Text("Personnes qui vous ont écrit sans vérification QR. Pas de réponse possible avant de scanner leur QR en personne.")
                    .font(.footnote).foregroundStyle(theme.secondary)
            }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }
    }
}

private struct WeshRequestDetail: View {
    let runtime: AppRuntime
    let requestID: String
    @ObservedObject private var requests = WeshInboundRequests.shared
    @ObservedObject private var trust = WeshQRTrust.shared
    @Environment(\.weshTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var confirmBlock = false
    @State private var confirmDelete = false

    private var request: WeshInboundRequests.Request? { requests.requests.first { $0.id == requestID } }

    var body: some View {
        List {
            if let request {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(request.nickname).font(.title2.weight(.semibold))
                        Text("Identité · " + String(request.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(theme.secondary)
                        Text(trust.fingerprints.contains(request.id)
                             ? "Contact vérifié. Écrivez-lui depuis Discussions."
                             : "Non vérifié. Un surnom ne prouve pas une identité. Vous ne pouvez pas répondre avant de scanner son QR en personne.")
                            .font(.subheadline).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 8)
                }.listRowBackground(theme.canvas)
                Section {
                    ForEach(request.messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.content).font(.body).textSelection(.enabled)
                            Text(message.timestamp, style: .time).font(.caption).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 6)
                    }
                } header: { WeshSectionLabel(text: "Messages reçus") }
                .listRowBackground(theme.canvas)
                Section {
                    if !trust.fingerprints.contains(request.id) {
                        Button { scanning = true } label: { Label("Scanner son QR pour vérifier", systemImage: "qrcode.viewfinder") }
                            .frame(minHeight: 44)
                    }
                    Button("Bloquer sur ce téléphone", role: .destructive) { confirmBlock = true }.frame(minHeight: 44)
                    Button("Supprimer la demande", role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
                }.listRowBackground(theme.canvas)
            } else {
                Text("Cette demande n’est plus disponible.").listRowBackground(theme.canvas)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("Demande").weshInlineTitle().weshCanvas(title: "Demande")
        .sheet(isPresented: $scanning) { WeshContactSheet(runtime: runtime) }
        .alert("Bloquer cette personne ?", isPresented: $confirmBlock) {
            Button("Annuler", role: .cancel) {}
            Button("Bloquer", role: .destructive) {
                if let request {
                    runtime.chatViewModel.blockMeshPeer(peerID: request.peerID, displayName: request.nickname)
                    requests.remove(request.id)
                }
                dismiss()
            }
        } message: { Text("Ses prochains messages seront ignorés sur ce téléphone et cette demande sera supprimée.") }
        .alert("Supprimer cette demande ?", isPresented: $confirmDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                requests.remove(requestID)
                dismiss()
            }
        } message: { Text("Les messages de cette demande seront effacés de ce téléphone.") }
    }
}
