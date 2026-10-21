import BitFoundation
import Combine
import Foundation
import SwiftUI

/// Public pages and the report address referenced from the app. One place, so a domain change is one line.
enum WeshLinks {
    static let terms = URL(string: "https://wesh.samourai.app/conditions")!
    /// Reports the user chooses to send reach the publisher here, by an e-mail they write and send.
    static let reportEmail = "support@samourai.coop"
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
        // Sender-chosen and kept raw: every view draws it through `PaveDisplayName.safe`, once.
        let nickname = message.sender
        let shown = BitchatMessage(
            id: message.id, sender: message.sender,
            content: WeshIncomingMediaPolicy.displayText(message.content),
            timestamp: message.timestamp, isRelay: false, originalSender: nil, isPrivate: true,
            recipientNickname: message.recipientNickname, senderPeerID: PeerID(hexData: noiseKey)
        )
        if let index = requests.firstIndex(where: { $0.id == fingerprint }) {
            guard !requests[index].messages.contains(where: { $0.id == message.id }) else { return false }
            requests[index].nickname = nickname
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
        requests.append(Request(noiseKey: noiseKey, nickname: nickname, messages: [shown], receivedAt: date))
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
    /// App information is generated locally. A remote peer may still pick the
    /// nickname "system"; it stays an ordinary, blockable sender.
    static func isLocalSystem(_ message: BitchatMessage) -> Bool {
        message.sender == "system" && message.senderPeerID == nil
    }

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

    var ignoresFavoriteNotices: Bool { weshPrivatePolicyEnabled }

    @MainActor
    func qrContactNickname(forNoiseKey noiseKey: Data) -> String? {
        guard weshPrivatePolicyEnabled else { return nil }
        return WeshQRTrust.shared.contacts.first(where: { Data(hexString: $0.noiseKeyHex) == noiseKey })?.nickname
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

    /// The local part of a report: it blocks the author and removes their public
    /// messages from this timeline. Sending the report to the Wesh team is a
    /// separate, optional e-mail the user writes (`PaveReportSendFlow`).
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

/// Confirmation, then outcome, for a report: the local block first, then the
/// optional e-mail to the Wesh team. Kept out of the conversation body so its
/// builder stays cheap to type-check.
struct WeshReportAlerts: ViewModifier {
    @Binding var target: PeerID?
    let name: String
    /// The reported public message: its sender as received and its text.
    let message: BitchatMessage?
    @Binding var done: Bool
    let report: (PeerID, String) -> Bool
    @State private var failed = false
    @State private var offer: PaveReportTarget?
    @State private var sending: PaveReportTarget?

    func body(content: Content) -> some View {
        content
            .alert(PaveCopy.text("pave.wesh.report.title"), isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) { target = nil }
                Button(PaveCopy.text("pave.wesh.report.action"), role: .destructive) {
                    if let target {
                        let mailTarget = PaveReportTarget(
                            rawNickname: message?.sender ?? name, fingerprint: PaveFingerprint.short(target.noiseKey),
                            source: .publicMessage(WeshIncomingMediaPolicy.displayText(message?.content ?? "")))
                        let (reported, next) = PaveReportMail.blockThenOffer(mailTarget) { report(target, name) }
                        offer = next
                        done = reported
                        failed = !reported
                    }
                    target = nil
                }
            } message: {
                // The nickname is chosen by the sender: it never leads the sentence.
                Text(PaveReportCopy.localBlock)
            }
            .alert(PaveCopy.text("pave.wesh.report.confirmed"), isPresented: $done) {
                Button(PaveReportCopy.sendAction) { sending = offer; offer = nil }
                Button(PaveCopy.text("pave.wesh.action.ok"), role: .cancel) { offer = nil }
            } message: {
                Text(PaveCopy.text("pave.wesh.report.confirmedBody"))
            }
            .alert(PaveCopy.text("pave.wesh.report.failed"), isPresented: $failed) {
                Button(PaveReportCopy.sendAction) { sending = offer; offer = nil }
                Button(PaveCopy.text("pave.wesh.action.ok"), role: .cancel) { offer = nil }
            } message: {
                Text(PaveCopy.text("pave.wesh.report.failedBody"))
            }
            .paveReportSendFlow($sending)
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
                            Text(PaveDisplayName.safe(request.nickname)).font(.headline)
                            PaveFingerprintText(fingerprint: PaveFingerprint.short(request.noiseKey))
                            Text(PaveCopy.text("pave.wesh.request.count", request.messages.count))
                                .font(.subheadline).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 8)
                    }
                    .accessibilityLabel(PaveCopy.text("pave.wesh.request.accessibility", PaveDisplayName.safe(request.nickname), PaveFingerprint.accessibilityText(PaveFingerprint.short(request.noiseKey))))
                }
            } header: { WeshSectionLabel(text: PaveCopy.text("pave.inbox.requests")) } footer: {
                Text(PaveCopy.text("pave.wesh.request.scope"))
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
    @State private var reportOffer: PaveReportTarget?

    private var request: WeshInboundRequests.Request? { requests.requests.first { $0.id == requestID } }

    var body: some View {
        List {
            if let request {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PaveDisplayName.safe(request.nickname)).font(.title2.weight(.semibold))
                        PaveFingerprintText(fingerprint: PaveFingerprint.short(request.noiseKey))
                        Text(trust.fingerprints.contains(request.id)
                             ? PaveCopy.text("pave.wesh.request.verified")
                             : PaveCopy.text("pave.wesh.request.unverified"))
                            .font(.subheadline).foregroundStyle(theme.secondary)
                    }.padding(.vertical, 8)
                }.listRowBackground(theme.canvas)
                Section {
                    ForEach(request.messages, id: \.id) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.content).font(.body)
                            Text(message.timestamp, style: .time).font(.caption).foregroundStyle(theme.secondary)
                        }.padding(.vertical, 6)
                    }
                } header: { WeshSectionLabel(text: PaveCopy.text("pave.wesh.request.messages")) }
                .listRowBackground(theme.canvas)
                Section {
                    if !trust.fingerprints.contains(request.id) {
                        Button { scanning = true } label: { Label(PaveCopy.text("pave.wesh.request.scan"), systemImage: "qrcode.viewfinder") }
                            .frame(minHeight: 44)
                    }
                    Button(PaveCopy.text("pave.wesh.block.onPhone"), role: .destructive) { confirmBlock = true }.frame(minHeight: 44)
                    Button(PaveCopy.text("pave.wesh.request.delete"), role: .destructive) { confirmDelete = true }.frame(minHeight: 44)
                }.listRowBackground(theme.canvas)
            } else {
                Text(PaveCopy.text("pave.wesh.request.unavailable")).listRowBackground(theme.canvas)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle(PaveCopy.text("pave.wesh.request.title")).weshInlineTitle().weshCanvas(title: PaveCopy.text("pave.wesh.request.title"))
        .sheet(isPresented: $scanning) { WeshContactSheet(runtime: runtime) }
        .alert(PaveCopy.text("pave.wesh.block.personTitle"), isPresented: $confirmBlock) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
            Button(PaveCopy.text("pave.wesh.action.block"), role: .destructive) {
                guard let request else { return dismiss() }
                // Nickname and fingerprint only: the request's private messages never leave.
                reportOffer = PaveReportMail.blockThenOffer(.request(request)) {
                    runtime.chatViewModel.blockMeshPeer(peerID: request.peerID, displayName: PaveDisplayName.safe(request.nickname))
                    requests.remove(request.id)
                    return true
                }.offer
            }
        } message: { Text(PaveCopy.text("pave.wesh.request.blockBody")) }
        .paveReportSendFlow($reportOffer) { dismiss() }
        .alert(PaveCopy.text("pave.wesh.request.deleteTitle"), isPresented: $confirmDelete) {
            Button(PaveCopy.text("pave.action.cancel"), role: .cancel) {}
            Button(PaveCopy.text("pave.wesh.action.delete"), role: .destructive) {
                requests.remove(requestID)
                dismiss()
            }
        } message: { Text(PaveCopy.text("pave.wesh.request.deleteBody")) }
    }
}
