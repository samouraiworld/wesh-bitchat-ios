import BitFoundation
import CoreBluetooth
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct WeshRootView: View {
    let runtime: AppRuntime
    @AppStorage("wesh.appearance.v1") private var appearance: WeshAppearance = .night
    @State private var selectedTab = 0
    @State private var keyboardVisible = false
    private var theme: WeshTheme { WeshTheme(appearance: appearance) }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                NavigationStack { WeshInbox(runtime: runtime) }
                    .tabItem { Label("Discussions", systemImage: "bubble.left.and.bubble.right") }
                    .tag(0).toolbar(.hidden, for: .tabBar)
                NavigationStack { WeshSettings(runtime: runtime) }
                    .tabItem { Label("Réglages", systemImage: "gearshape") }
                    .tag(1).toolbar(.hidden, for: .tabBar)
            }
            if !keyboardVisible { VStack(spacing: 0) {
                Rectangle().fill(theme.line).frame(height: 0.5)
                HStack(spacing: 0) {
                    tab("Discussions", symbol: "bubble.left.and.bubble.right", index: 0)
                    tab("Réglages", symbol: "gearshape", index: 1)
                }.padding(.top, 8).padding(.bottom, 4)
            }.background(theme.canvas.ignoresSafeArea(edges: .bottom)) }
        }
        .environment(\.weshTheme, theme)
        .environment(\.colorScheme, theme.scheme)
        .tint(theme.accent)
        .preferredColorScheme(theme.scheme)
        .background(theme.canvas.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }

    private func tab(_ title: String, symbol: String, index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3.weight(selectedTab == index ? .semibold : .regular))
                Text(title).font(.caption.weight(selectedTab == index ? .semibold : .regular))
            }.frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(selectedTab == index ? theme.accent : theme.secondary)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }
}

private struct WeshInbox: View {
    let runtime: AppRuntime
    @EnvironmentObject private var inbox: PrivateInboxModel
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var addingContact = false
    @EnvironmentObject private var peers: PeerListModel

    private var contacts: [WeshQRTrust.Contact] {
        let _ = peers.renderID
        return trust.contacts.filter { row in
            guard let key = row.peerID.noiseKey else { return false }
            return !runtime.chatViewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint())
        }
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WeshConversation(runtime: runtime, peerID: nil, title: "Salon local")
                } label: {
                    HStack(spacing: 16) {
                        WeshAvatar(symbol: "antenna.radiowaves.left.and.right")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Salon local").font(.headline)
                            Text("Une conversation ouverte autour de vous.")
                                .font(.subheadline).foregroundStyle(theme.secondary)
                        }
                        Spacer(minLength: 0)
                        Text("Public").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                    }.padding(.vertical, theme.isDark ? 14 : 8)
                }
            } header: { WeshSectionLabel(text: "À proximité") } footer: {
                Label(bluetoothSummary(chrome.bluetoothState), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote).foregroundStyle(theme.secondary).padding(.top, 8)
                if chrome.bluetoothState == .unauthorized {
                    Button("Autoriser le Bluetooth", action: openWeshSystemSettings).frame(minHeight: 44)
                }
            }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)

            Section {
                if contacts.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Un QR. Et on se parle.")
                            .font(.title2.weight(.semibold))
                        Text("Ajoutez une personne en face de vous pour commencer une discussion privée.")
                            .font(.body).foregroundStyle(theme.secondary)
                        Button { addingContact = true } label: {
                            Label("Ajouter un contact", systemImage: "qrcode.viewfinder")
                        }.buttonStyle(WeshPrimaryButtonStyle())
                    }.padding(.vertical, 24)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(contacts) { row in
                        NavigationLink {
                            WeshConversation(runtime: runtime, peerID: row.peerID, title: row.nickname)
                        } label: {
                            HStack(spacing: 16) {
                                WeshAvatar(symbol: "person")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.nickname).font(.headline)
                                    Text(inbox.messages(for: row.peerID).last?.content ?? "Identité vérifiée sur ce téléphone")
                                        .lineLimit(2).font(.subheadline).foregroundStyle(theme.secondary)
                                }
                                Spacer(minLength: 4)
                                if inbox.unreadPeerIDs.contains(row.peerID) || inbox.unreadPeerIDs.contains(runtime.chatViewModel.getShortIDForNoiseKey(row.peerID)) {
                                    Image(systemName: "circle.fill").font(.caption2).foregroundStyle(theme.accent).accessibilityLabel("Messages non lus")
                                }
                            }.padding(.vertical, theme.isDark ? 12 : 6)
                        }
                    }
                }
            } header: { WeshSectionLabel(text: "Discussions privées") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("Wesh")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingContact = true } label: {
                    Label("Ajouter un contact", systemImage: "plus").frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .sheet(isPresented: $addingContact) { WeshContactSheet(runtime: runtime) }
        .weshCanvas(title: "Wesh")
    }
}

private struct WeshAvatar: View {
    let symbol: String
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(theme.accent)
            .frame(width: 48, height: 48)
            .overlay(RoundedRectangle(cornerRadius: theme.isDark ? 24 : 14).strokeBorder(theme.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct WeshConversation: View {
    let runtime: AppRuntime
    let peerID: PeerID?
    let title: String
    @EnvironmentObject private var publicChat: PublicChatModel
    @EnvironmentObject private var inbox: PrivateInboxModel
    @EnvironmentObject private var privateChat: PrivateConversationModel
    @EnvironmentObject private var verification: VerificationModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var draft = ""
    @State private var publicWarning = false
    @State private var information = false
    @Environment(\.weshTheme) private var theme
    @State private var contactSheet = false
    @State private var contactDetails = false
    @State private var blockTarget: PeerID?
    @State private var blockName = ""
    @State private var showingParticipants = false
    @AppStorage("wesh.publicMuted") private var publicMuted = false
    @EnvironmentObject private var actions: ConversationUIModel
    @AppStorage("wesh.publicDisclosureAccepted.v1") private var publicAccepted = false
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

    @EnvironmentObject private var peers: PeerListModel

    private var isPrivate: Bool { peerID != nil }
    private var draftKey: ComposerDraftStore.Key {
        .from(peerID: peerID, fingerprint: peerID?.noiseKey?.sha256Fingerprint(), channel: .mesh)
    }
    private var canSend: Bool {
        let _ = peers.renderID
        return peerID.map { runtime.chatViewModel.canSendWeshPrivate(to: $0) } ?? runtime.chatViewModel.canSendWeshPublic
    }
    private var messages: [BitchatMessage] {
        if let peerID {
            let stableMessages = inbox.messages(for: peerID)
            if !stableMessages.isEmpty { return stableMessages.filter(\.isPrivate) }
            // A mutable selection must never put another person's history under this title.
            if let selected = privateChat.selectedPeerID, let pinned = peerID.noiseKey,
               runtime.chatViewModel.noiseSessionPublicKeyData(for: runtime.chatViewModel.getShortIDForNoiseKey(selected)) == pinned {
                return inbox.messages(for: selected).filter(\.isPrivate)
            }
            return []
        }
        guard publicChat.activeChannel == .mesh else { return [] }
        return publicChat.messages.filter { !$0.isPrivate && !$0.isBridged }
    }

    var body: some View {
        let displayedMessages = messages
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(isPrivate ? (canSend ? "Identité vérifiée sur ce téléphone" : "Vérification ou connexion requise") : "Public · Messages relayables",
                                          systemImage: isPrivate ? "lock" : "antenna.radiowaves.left.and.right")
                                        .font(.subheadline.weight(.medium))
                                    if !isPrivate {
                                        Text("Visible par les participants au salon.")
                                            .font(.footnote).foregroundStyle(theme.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Button { information = true } label: {
                                    Image(systemName: "info.circle").frame(width: 44, height: 44)
                                }.accessibilityLabel(isPrivate ? "À propos de cette discussion privée" : "À propos du salon public")
                            }
                            if isPrivate && !canSend {
                                Button("Vérifier le contact") { contactSheet = true }.frame(minHeight: 44)
                            }
                        }.padding(.bottom, 16)
                        if displayedMessages.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: isPrivate ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 40, weight: .light)).foregroundStyle(theme.accent).accessibilityHidden(true)
                                Text(isPrivate ? "Votre discussion commence ici." : (canSend ? "Un premier salut ?" : "Le salon est prêt."))
                                    .font(.title2.weight(.semibold))
                                Text(isPrivate ? "Écrivez quand votre contact est connecté." : (canSend ? "Entrez dans la conversation.\nAucun contact à ajouter." : "Préparez un message. Il restera ici tant que l’envoi est indisponible."))
                                    .font(.body).foregroundStyle(theme.secondary)
                            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 64)
                        }
                        ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                            if WeshTimeline.startsDay(at: message.timestamp, after: index > 0 ? displayedMessages[index - 1].timestamp : nil) {
                                WeshDayDivider(date: message.timestamp)
                            }
                            WeshMessageBubble(message: message,
                                own: runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID, displayName: message.sender),
                                privateChat: isPrivate).id(message.id)
                                .accessibilityAction(named: "Copier le message") { UIPasteboard.general.string = message.content }
                                .contextMenu {
                                    Button { UIPasteboard.general.string = message.content } label: {
                                        Label("Copier", systemImage: "doc.on.doc")
                                    }
                                    if !runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID, displayName: message.sender), message.sender != "system", let identity = WeshMessageActions.blockIdentity(messageSender: message.senderPeerID, pinnedConversation: peerID) {
                                        Button("Bloquer sur ce téléphone", role: .destructive) { blockTarget = identity; blockName = isPrivate ? title : message.sender }
                                    }
                                }
                        }
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: displayedMessages.count) { _ in
                    if let id = displayedMessages.last?.id {
                        if reduceMotion { scroll.scrollTo(id, anchor: .bottom) }
                        else { withAnimation { scroll.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
        }
        .weshCanvas(title: title)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if !canSend {
                    Text(isPrivate ? "Votre brouillon reste ici. Vérifiez le contact et la connexion pour envoyer." : bluetoothSummary(chrome.bluetoothState))
                        .font(.footnote).foregroundStyle(theme.secondary)
                    if !isPrivate && chrome.bluetoothState == .unauthorized {
                        Button("Autoriser le Bluetooth", action: openWeshSystemSettings).frame(minHeight: 44)
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(isPrivate ? "Message privé" : "Message public", text: $draft,
                              prompt: Text(isPrivate ? "Message privé" : "Message public").foregroundColor(theme.secondary), axis: .vertical)
                        .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                        .focused($composerFocused)
                        .padding(14)
                        .overlay(RoundedRectangle(cornerRadius: theme.radius).strokeBorder(theme.line, lineWidth: 1))
                        .accessibilityLabel(isPrivate ? "Message privé" : "Message public")
                    Button {
                        if !isPrivate && !publicAccepted { publicWarning = true } else { send() }
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .foregroundStyle(canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.onAccent : theme.secondary)
                            .background(canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(theme.metalFill) : AnyShapeStyle(theme.canvas), in: Circle())
                            .overlay(Circle().strokeBorder(theme.line, lineWidth: canSend ? 0 : 1))
                    }
                    .accessibilityLabel(isPrivate ? "Envoyer le message privé" : "Envoyer publiquement")
                    .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(16).background(theme.canvas)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let peerID, trust.contacts.contains(where: { $0.peerID == peerID }) {
                        Button { contactDetails = true } label: { Label("Voir le contact", systemImage: "person.crop.circle") }
                    }
                    Button { information = true } label: { Label("À propos", systemImage: "info.circle") }
                    if !isPrivate {
                        Button { showingParticipants = true } label: { Label("Participants connus", systemImage: "person.2") }
                        Button { publicMuted.toggle() } label: {
                            Label(publicMuted ? "Réactiver les mentions" : "Mettre les mentions en sourdine", systemImage: publicMuted ? "bell.slash" : "bell")
                        }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Actions de conversation")
            }
        }
        .alert("Envoyer dans un salon public ?", isPresented: $publicWarning) {
            Button("Annuler", role: .cancel) {}
            Button("Envoyer publiquement") { publicAccepted = true; send() }
        } message: { Text("Tout participant au salon peut voir, conserver ou relayer ce message. Le Bluetooth ne garantit aucune frontière géographique. Un surnom ne prouve pas une identité. Votre brouillon reste ici si vous annulez.") }
        .sheet(isPresented: $contactSheet) { WeshContactSheet(runtime: runtime) }
        .alert("Bloquer cette personne ?", isPresented: Binding(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } })) {
            Button("Annuler", role: .cancel) { blockTarget = nil }
            Button("Bloquer", role: .destructive) {
                if let target = blockTarget { actions.block(peerID: target, displayName: blockName) }
                blockTarget = nil
            }
        } message: { Text("Ses prochains messages seront ignorés sur ce téléphone. L’historique existant reste ici. Vous pourrez la débloquer dans Réglages → Contacts bloqués.") }
        .sheet(isPresented: $showingParticipants) { NavigationStack { WeshNearbyPeople(runtime: runtime) }.weshSheetBackground() }
        .sheet(isPresented: $contactDetails) {
            if let peerID, let contact = trust.contacts.first(where: { $0.peerID == peerID }) {
                NavigationStack { WeshContactDetails(runtime: runtime, contact: contact, inSheet: true) }.weshSheetBackground()
            }
        }
        .sheet(isPresented: $information) {
            WeshInformationSheet(isPrivate: isPrivate)
        }
        .onAppear {
            draft = ComposerDraftStore.load(draftKey)
            if let peerID { privateChat.startConversation(with: peerID) }
            else { privateChat.endConversation(); runtime.chatViewModel.switchLocationChannel(to: .mesh) }
        }
        .onChange(of: draft) { value in ComposerDraftStore.save(value, for: draftKey) }
    }

    private func send() {
        if runtime.chatViewModel.sendWeshDraft(&draft, to: peerID) { composerFocused = false }
    }
}

enum WeshTimeline {
    static func startsDay(at date: Date, after previous: Date?, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }
}

private struct WeshDayDivider: View {
    let date: Date
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Group {
            if Calendar.current.isDateInToday(date) { Text("Aujourd’hui") }
            else if Calendar.current.isDateInYesterday(date) { Text("Hier") }
            else { Text(date, format: .dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))) }
        }.font(.caption.weight(.medium)).foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct WeshMessageBubble: View {
    let message: BitchatMessage
    let own: Bool
    let privateChat: Bool
    @Environment(\.weshTheme) private var theme
    private var filled: Bool { own && !theme.isDark }
    @ViewBuilder private var metadata: some View {
        Text(message.timestamp, style: .time)
        if own, privateChat { Text(WeshDelivery.label(message.deliveryStatus)) }
        else if own { Text(WeshDelivery.publicLabel(message.deliveryStatus)) }
    }
    var body: some View {
        HStack {
            if own { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if !own && (!privateChat || message.sender == "system") { Text(message.sender == "system" ? "Information" : message.sender).font(.caption.weight(.semibold)).foregroundStyle(filled ? theme.onAccent : theme.secondary) }
                Text(message.content).font(.body).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { metadata }
                    VStack(alignment: .leading, spacing: 4) { metadata }
                }.font(.caption).foregroundStyle(filled ? theme.onAccent : theme.secondary)
            }.padding(14)
                .foregroundStyle(filled ? theme.onAccent : theme.ink)
                .background(filled ? theme.accent : theme.canvas, in: RoundedRectangle(cornerRadius: theme.messageRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.messageRadius).strokeBorder(theme.line, lineWidth: filled ? 0 : 1))
            if !own { Spacer(minLength: 32) }
        }
    }
}

enum WeshDelivery {
    static func publicLabel(_ status: DeliveryStatus) -> String {
        switch status {
        case .notSentYet: return "En attente de diffusion"
        case .sending: return "Diffusion en cours"
        case .failed: return "Échec de diffusion"
        case .partiallyDelivered: return "Transmission partielle · réception non confirmée"
        default: return "Diffusion publique · réception non confirmée"
        }
    }

    static func label(_ status: DeliveryStatus) -> String {
        switch status {
        case .notSentYet: return "En attente d’envoi"
        case .sending: return "En cours d’envoi"
        case .sent: return "Parti de ce téléphone"
        case .carried: return "Confié à un relais · réception non confirmée"
        case .delivered: return "Réception confirmée"
        case .read: return "Lu"
        case .failed: return "Échec d’envoi"
        case .partiallyDelivered: return "Transmission partielle"
        }
    }
}

private struct WeshContactSheet: View {
    let runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    @EnvironmentObject private var verification: VerificationModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var showingScanner = false
    @State private var scanning = false
    @State private var cameraUnavailable = false
    @State private var status = ""
    @State private var scannedKey: Data?
    @State private var scannedName = ""
    @State private var qr = ""
    @State private var pastedQR = ""
    @FocusState private var pastedQRFocused: Bool
    private enum QRFocus: Hashable { case result, camera }
    @AccessibilityFocusState(for: .voiceOver) private var accessibilityFocus: QRFocus?
    @State private var focusTarget: QRFocus = .result
    @State private var focusRevision = 0
    @State private var waitingForKeyboard = false
    @State private var progress: ChatVerificationCoordinator.QRProgress = .unavailable
    private let renewal = Timer.publish(every: 45, on: .main, in: .common).autoconnect()
    private let progressRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 4) {
                        mode("Mon QR", scanner: false)
                        mode("Scanner", scanner: true)
                    }.padding(4).overlay(RoundedRectangle(cornerRadius: theme.radius + 4).strokeBorder(theme.line, lineWidth: 1))

                    if showingScanner {
                        if scannedKey != nil { verificationResult }
                        else {
                            if !status.isEmpty { resultMessage(status) }
                            scannerContent
                        }
                    } else {
                        VStack(spacing: 12) {
                            Text(progress == .verified ? "À son tour de scanner." : "Présentez votre QR.")
                                .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text("Sur votre écran, en personne.\nVotre contact pourra alors vous écrire.")
                                .foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.top, 12)
                        if qr.isEmpty {
                            ProgressView("Préparation de votre QR…").frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            GeometryReader { geometry in
                                QRCodeImage(data: qr, size: min(260, max(120, geometry.size.width - 32)))
                                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 24))
                                    .frame(maxWidth: .infinity)
                                    .accessibilityLabel("Votre QR d’identité à montrer en direct, pas une photo")
                            }.frame(height: 292)
                        }
                        Text("Ce QR se renouvelle automatiquement.")
                            .font(.footnote).foregroundStyle(theme.secondary).frame(maxWidth: .infinity)
                        Button { selectMode(scanner: true) } label: {
                            Label("Scanner son QR", systemImage: "qrcode.viewfinder")
                        }.buttonStyle(WeshPrimaryButtonStyle())
                    }

                    DisclosureGroup("Comment ça marche ?") {
                        Text("Chacun scanne le QR affiché en direct par l’autre. Une photo ou un lien transféré ne prouve pas qui vous rencontrez. La vérification vaut sur ce téléphone : elle ne confirme pas ce que l’autre personne a vérifié.")
                            .font(.subheadline).foregroundStyle(theme.secondary).padding(.top, 12)
                    }.padding(.top, 4)
                }.padding(theme.contentInset)
            }
            .onChange(of: focusRevision) { _ in
                scroll.scrollTo(focusTarget, anchor: .top)
                DispatchQueue.main.async { accessibilityFocus = focusTarget }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ajouter un contact").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() }.frame(minHeight: 44) } }
            .onAppear { qr = verification.myQRString() }
            .onReceive(renewal) { _ in qr = verification.myQRString() }
            .onReceive(progressRefresh) { _ in refreshProgress() }
            .onChange(of: trust.fingerprints) { _ in refreshProgress() }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                guard waitingForKeyboard else { return }
                waitingForKeyboard = false
                focusResult()
            }
            .onDisappear { scanning = false }
            .weshCanvas(title: "Ajouter un contact")
            }
        }.weshSheetBackground()
    }

    private func mode(_ title: String, scanner: Bool) -> some View {
        Button { selectMode(scanner: scanner) } label: {
            Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(showingScanner == scanner ? theme.onAccent : theme.secondary)
                .background(showingScanner == scanner ? AnyShapeStyle(theme.metalFill) : AnyShapeStyle(theme.canvas), in: RoundedRectangle(cornerRadius: theme.radius))
        }.buttonStyle(.plain).accessibilityAddTraits(showingScanner == scanner ? .isSelected : [])
            .accessibilityHint(scanner ? "Vérifier l’identité du contact devant vous" : "Montrer votre identité à votre contact")
    }

    private func resultMessage(_ message: String) -> some View {
        Text(message).font(.subheadline)
            .id(QRFocus.result)
            .accessibilityFocused($accessibilityFocus, equals: .result)
    }

    @ViewBuilder private var verificationResult: some View {
        if progress == .verified {
            VStack(alignment: .leading, spacing: 12) {
                Label("Identité vérifiée ici", systemImage: "checkmark.shield")
                    .font(.title2.weight(.semibold)).foregroundStyle(theme.accent)
                Text(scannedName).font(.headline)
                Text("Sur ce téléphone, vous avez vérifié votre contact. Pour qu’il puisse vous écrire, montrez-lui maintenant votre QR.")
                    .foregroundStyle(theme.secondary)
            }.accessibilityElement(children: .combine)
                .id(QRFocus.result)
                .accessibilityFocused($accessibilityFocus, equals: .result)
            Button { selectMode(scanner: false) } label: {
                Label("Montrer mon QR", systemImage: "qrcode")
            }.buttonStyle(WeshPrimaryButtonStyle())
            Button("Scanner un autre contact", action: retryScan).frame(minHeight: 44)
        } else if progress == .pending {
            VStack(alignment: .leading, spacing: 12) {
                Text("Vérification en cours…").font(.title2.weight(.semibold))
                Text(status).foregroundStyle(theme.secondary)
            }.accessibilityElement(children: .combine)
                .id(QRFocus.result)
                .accessibilityFocused($accessibilityFocus, equals: .result)
            Button("Scanner à nouveau", action: retryScan).frame(minHeight: 44)
        } else {
            resultMessage("Pas de confirmation. Gardez Wesh ouvert sur les deux téléphones, puis réessayez.")
            Button("Réessayer le scan", action: retryScan).buttonStyle(WeshPrimaryButtonStyle())
        }
    }

    @ViewBuilder private var scannerContent: some View {
        Text("Scannez son QR.").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
        Text("Visez le QR affiché en direct sur le téléphone de votre contact.").foregroundStyle(theme.secondary)
        if scanning {
            CameraScannerView(isActive: scanning, onUnavailable: {
                cameraUnavailable = true; scanning = false; focusResult(.camera)
            }, onCode: { value in
                guard scanning else { return }
                scan(value)
            })
                .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: theme.radius))
                .accessibilityLabel("Scanner le QR du contact")
            Button("Arrêter la caméra") { scanning = false }.frame(minHeight: 44)
        } else {
            if cameraUnavailable {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Caméra indisponible", systemImage: "camera")
                        .font(.headline)
                    Text("Autorisez la caméra dans les réglages, ou comparez le lien en personne avec « Autre méthode ».")
                        .font(.subheadline).foregroundStyle(theme.secondary)
                }.padding(.vertical, 12).accessibilityElement(children: .combine)
                    .id(QRFocus.camera)
                    .accessibilityFocused($accessibilityFocus, equals: .camera)
                Button("Ouvrir les réglages", action: openWeshSystemSettings).frame(minHeight: 44)
            }
            Button { cameraUnavailable = false; scanning = true } label: {
                Label("Scanner le QR du contact", systemImage: "qrcode.viewfinder")
            }.buttonStyle(WeshPrimaryButtonStyle())
        }
        DisclosureGroup("Autre méthode") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Comparez le lien sur l’écran de la personne devant vous avant de le coller.")
                    .font(.subheadline).foregroundStyle(theme.secondary)
                TextField("Lien QR", text: $pastedQR, axis: .vertical)
                    .lineLimit(2...5).focused($pastedQRFocused).padding(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.line, lineWidth: 1))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Lien du QR de votre contact")
                    .accessibilityHint("À comparer en personne avec le lien affiché sur son téléphone")
                Button("Vérifier ce QR") { scan(pastedQR) }
                    .buttonStyle(WeshPrimaryButtonStyle()).disabled(pastedQR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 12)
        }
    }

    private func selectMode(scanner: Bool) {
        pastedQRFocused = false
        showingScanner = scanner
        scanning = scanner && scannedKey == nil
        cameraUnavailable = false
    }
    private func retryScan() {
        scannedKey = nil; scannedName = ""; status = ""; progress = .unavailable
        selectMode(scanner: true)
    }
    private func focusResult(_ target: QRFocus = .result) {
        accessibilityFocus = nil
        focusTarget = target
        guard !waitingForKeyboard else { return }
        focusRevision += 1
    }
    private func scan(_ value: String) {
        waitingForKeyboard = pastedQRFocused
        pastedQRFocused = false
        scanning = false
        scannedKey = nil
        scannedName = ""
        progress = .unavailable
        if let scannedURL = URL(string: value),
           let parsed = VerificationService.VerificationQR.fromURL(scannedURL),
           let ownURL = URL(string: qr),
           let own = VerificationService.VerificationQR.fromURL(ownURL),
           parsed.noiseKeyHex == own.noiseKeyHex,
           VerificationService.shared.verifyScannedQR(value) != nil {
            status = "C’est votre QR. Scannez celui de votre contact."
            focusResult()
            return
        }
        switch verification.verifyScannedPayload(value) {
        case .invalid: status = "QR invalide ou expiré. Demandez un nouveau QR à votre contact."
        case .notFound: status = "Contact introuvable ou identité différente. Rapprochez les téléphones et réessayez."
        case .requested(let name):
            scannedName = name
            if let url = URL(string: value), let parsed = VerificationService.VerificationQR.fromURL(url) { scannedKey = Data(hexString: parsed.noiseKeyHex) }
            status = "Vérification de \(name) en cours… Gardez Wesh ouvert sur les deux téléphones."
            refreshProgress()
        }
        focusResult()
    }
    private func refreshProgress() {
        guard let scannedKey else { return }
        let updated = runtime.chatViewModel.weshQRProgress(for: scannedKey)
        guard updated != progress else { return }
        progress = updated
        if showingScanner { focusResult() }
    }
}

private struct WeshInformationSheet: View {
    let isPrivate: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: isPrivate ? "lock" : "antenna.radiowaves.left.and.right")
                        .font(.largeTitle).foregroundStyle(theme.accent).accessibilityHidden(true)
                    Text(isPrivate ? "Une vérification en personne." : "Un salon ouvert.")
                        .font(.title2.weight(.semibold))
                    Text(isPrivate ? "Pour échanger, chacun doit scanner le QR de l’autre. L’identité vérifiée ici est liée à la connexion chiffrée de ce contact." : "Les participants peuvent voir, conserver et relayer vos messages. Un surnom ne prouve pas une identité.")
                    Text(isPrivate ? "La vérification sur ce téléphone ne prouve pas que votre contact vous a vérifié. En cas de changement d’identité ou de connexion, l’écriture est suspendue et votre brouillon est conservé." : "Le Bluetooth ne garantit aucune frontière géographique : un message peut être relayé au-delà des personnes proches. La diffusion ne confirme pas sa réception.")
                        .foregroundStyle(theme.secondary)
                    Text(isPrivate ? "Une réception confirmée concerne ce message et son destinataire. Une connexion disponible ou un relais ne suffit pas." : "La sourdine coupe les notifications de mentions. Pour bloquer quelqu’un sur ce téléphone, ouvrez le menu de conversation puis Participants connus.")
                        .font(.subheadline).foregroundStyle(theme.secondary)
                }.padding(theme.contentInset)
            }
            .navigationTitle(isPrivate ? "Discussion privée" : "À propos du salon").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() }.frame(minHeight: 44) } }
            .weshCanvas(title: isPrivate ? "Discussion privée" : "À propos du salon")
        }.weshSheetBackground()
    }
}

private func bluetoothSummary(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "Bluetooth actif"
    case .poweredOff: return "Activez le Bluetooth pour échanger à proximité"
    case .unauthorized: return "Autorisez le Bluetooth dans les réglages du téléphone"
    case .unsupported: return "Bluetooth indisponible sur cet appareil"
    default: return "Préparation du Bluetooth…"
    }
}

private struct WeshSettings: View {
    let runtime: AppRuntime
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    @State private var showQR = false
    var body: some View {
        List {
            Section {
                NavigationLink { WeshProfileEditor() } label: {
                    HStack(spacing: 16) {
                        WeshAvatar(symbol: "person")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chrome.nickname).font(.headline)
                            Text("Votre profil").font(.subheadline).foregroundStyle(theme.secondary)
                        }
                    }.padding(.vertical, theme.isDark ? 12 : 6)
                }
                Button { showQR = true } label: {
                    Label("Mon QR d’identité", systemImage: "qrcode").frame(minHeight: 48)
                }
            }.listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
            Section {
                NavigationLink { WeshAppearanceSettings() } label: {
                    HStack {
                        Label("Apparence", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Text(theme.appearance.title).foregroundStyle(theme.secondary)
                    }.frame(minHeight: 48)
                }
                NavigationLink { WeshMeetingNote() } label: {
                    Label("Note de rendez-vous", systemImage: "calendar").frame(minHeight: 48)
                }
            } header: { WeshSectionLabel(text: "À votre façon") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
            Section {
                NavigationLink { WeshContacts(runtime: runtime) } label: {
                    Label("Contacts", systemImage: "person.2").frame(minHeight: 48)
                }
                NavigationLink { WeshBlockedContacts(runtime: runtime) } label: {
                    Label("Contacts bloqués", systemImage: "hand.raised.slash").frame(minHeight: 48)
                }
            } header: { WeshSectionLabel(text: "Vos contacts") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
            Section {
                NavigationLink { WeshConnectionSettings() } label: {
                    Label("Connexion à proximité", systemImage: "antenna.radiowaves.left.and.right").frame(minHeight: 48)
                }
                NavigationLink { WeshPrivacySettings(runtime: runtime) } label: {
                    Label("Confidentialité", systemImage: "hand.raised").frame(minHeight: 48)
                }
            } header: { WeshSectionLabel(text: "Pour échanger") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .navigationTitle("Réglages").weshCanvas(title: "Réglages")
        .sheet(isPresented: $showQR) { WeshContactSheet(runtime: runtime) }
    }
}

private struct WeshContacts: View {
    let runtime: AppRuntime
    @ObservedObject private var trust = WeshQRTrust.shared
    @ObservedObject private var service: UnifiedPeerService
    @Environment(\.weshTheme) private var theme
    @State private var addingContact = false

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    var body: some View {
        List {
            Section {
                if trust.contacts.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Vos contacts, en personne.").font(.title2.weight(.semibold))
                        Text("Scannez le QR de quelqu’un pour commencer une discussion privée.").foregroundStyle(theme.secondary)
                        Button { addingContact = true } label: { Label("Ajouter un contact", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(WeshPrimaryButtonStyle())
                    }.padding(.vertical, 24).listRowSeparator(.hidden)
                } else {
                    ForEach(trust.contacts) { contact in
                        NavigationLink { WeshContactDetails(runtime: runtime, contact: contact) } label: {
                            HStack(spacing: 16) {
                                WeshAvatar(symbol: "person")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(contact.nickname).font(.headline)
                                    Text("Identité · " + String((contact.peerID.noiseKey?.sha256Fingerprint() ?? "").prefix(8))).font(.caption).foregroundStyle(theme.secondary)
                                    Text(isBlocked(contact) ? "Bloqué sur ce téléphone" : "Identité vérifiée ici")
                                        .font(.subheadline).foregroundStyle(theme.secondary)
                                }
                            }.padding(.vertical, 12)
                        }
                    }
                }
            } footer: { Text("Un surnom ne prouve pas une identité. Les vérifications et les blocages concernent ce téléphone.") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("Contacts").weshCanvas(title: "Contacts")
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Button { addingContact = true } label: { Label("Ajouter un contact", systemImage: "plus").frame(width: 44, height: 44) }
            } }
            .sheet(isPresented: $addingContact) { WeshContactSheet(runtime: runtime) }
    }

    private func isBlocked(_ contact: WeshQRTrust.Contact) -> Bool {
        guard let key = contact.peerID.noiseKey else { return false }
        return runtime.chatViewModel.identityManager.isBlocked(fingerprint: key.sha256Fingerprint())
    }
}

private struct WeshContactDetails: View {
    let runtime: AppRuntime
    let contact: WeshQRTrust.Contact
    var inSheet = false
    @ObservedObject private var service: UnifiedPeerService
    @ObservedObject private var trust = WeshQRTrust.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    @State private var removing = false
    @State private var blocking = false
    @State private var feedback = ""

    init(runtime: AppRuntime, contact: WeshQRTrust.Contact, inSheet: Bool = false) {
        self.runtime = runtime
        self.contact = contact
        self.inSheet = inSheet
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    private var blocked: Bool {
        contact.peerID.noiseKey.map { runtime.chatViewModel.identityManager.isBlocked(fingerprint: $0.sha256Fingerprint()) } ?? false
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    WeshAvatar(symbol: "person")
                    Text(contact.nickname).font(.title2.weight(.semibold))
                    Text("Identité · " + String((contact.peerID.noiseKey?.sha256Fingerprint() ?? "").prefix(8))).font(.caption.monospaced()).foregroundStyle(theme.secondary)
                    Label(blocked ? "Bloqué sur ce téléphone" : "Identité vérifiée ici", systemImage: blocked ? "hand.raised" : "lock")
                        .font(.subheadline).foregroundStyle(theme.secondary)
                    Text("Ce surnom vient du QR. La vérification concerne l’identité de connexion, sur ce téléphone seulement.")
                        .font(.subheadline).foregroundStyle(theme.secondary)
                }.padding(.vertical, 16)
            }.listRowBackground(theme.canvas)
            Section {
                if blocked {
                    Button("Débloquer") {
                        if let key = contact.peerID.noiseKey, runtime.chatViewModel.unblockWeshIdentity(key.sha256Fingerprint()) {
                            feedback = "Contact débloqué."
                        } else { feedback = "Ce contact n’est plus bloqué." }
                    }.frame(minHeight: 48)
                } else {
                    Button("Bloquer sur ce téléphone", role: .destructive) { blocking = true }.frame(minHeight: 48)
                }
                Button("Retirer ce contact", role: .destructive) { removing = true }.frame(minHeight: 48)
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: {
                Text("Le blocage ignore ses prochains messages ici et conserve l’historique existant. Retirer le contact suspend les prochains envois privés ; un nouveau scan sera nécessaire. Les messages déjà transmis ne peuvent pas être rappelés.")
            }.listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("Contact").navigationBarTitleDisplayMode(.inline).weshCanvas(title: "Contact")
            .toolbar { if inSheet { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() }.frame(minHeight: 44) } } }
            .alert("Bloquer ce contact ?", isPresented: $blocking) {
                Button("Annuler", role: .cancel) {}
                Button("Bloquer", role: .destructive) {
                    runtime.chatViewModel.blockMeshPeer(peerID: contact.peerID, displayName: contact.nickname)
                    feedback = "Contact bloqué sur ce téléphone."
                }
            } message: { Text("Vous pourrez le débloquer ici ou dans Réglages → Contacts bloqués, même s’il est hors connexion.") }
            .alert("Retirer ce contact ?", isPresented: $removing) {
                Button("Annuler", role: .cancel) {}
                Button("Retirer", role: .destructive) {
                    if let key = contact.peerID.noiseKey { runtime.chatViewModel.removeWeshContact(for: key) }
                    dismiss()
                }
            } message: { Text("Il disparaîtra des discussions. Ce retrait n’efface pas l’historique. Un nouveau scan sera nécessaire pour envoyer. Les envois en attente pourront reprendre après ce scan.") }
    }
}

private struct WeshNearbyPeople: View {
    let runtime: AppRuntime
    @ObservedObject private var service: UnifiedPeerService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.weshTheme) private var theme
    @State private var selected: WeshQRTrust.Contact?
    @State private var feedback = ""

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    private var participants: [BitchatPeer] {
        service.peers.filter { $0.noisePublicKey.count == 32 && ($0.isConnected || $0.isReachable) }
    }

    var body: some View {
        List {
            Section {
                if participants.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Aucun participant connu.").font(.title2.weight(.semibold))
                        Text("Les connexions Bluetooth disponibles apparaîtront ici.").foregroundStyle(theme.secondary)
                    }.padding(.vertical, 24).listRowSeparator(.hidden)
                } else {
                    ForEach(participants, id: \.peerID) { person in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(person.displayName).font(.headline)
                            Text("Identité · " + String(person.noisePublicKey.sha256Fingerprint().prefix(8)))
                                .font(.caption.monospaced()).foregroundStyle(theme.secondary)
                            if runtime.chatViewModel.identityManager.isBlocked(fingerprint: person.noisePublicKey.sha256Fingerprint()) {
                                Text("Bloqué sur ce téléphone").font(.subheadline).foregroundStyle(theme.secondary)
                            } else {
                                Button("Bloquer sur ce téléphone", role: .destructive) {
                                    selected = .init(noiseKeyHex: person.noisePublicKey.hexEncodedString(), nickname: person.displayName)
                                }.frame(minHeight: 44)
                            }
                        }.padding(.vertical, 8)
                    }
                }
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: { Text("Cette liste n’indique ni distance ni réception des messages. Un surnom ne prouve pas une identité. Pour débloquer : Réglages → Contacts bloqués.") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("Participants connus").navigationBarTitleDisplayMode(.inline).weshCanvas(title: "Participants connus")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() }.frame(minHeight: 44) } }
            .alert("Bloquer cette personne ?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
                Button("Annuler", role: .cancel) { selected = nil }
                Button("Bloquer", role: .destructive) {
                    if let person = selected {
                        runtime.chatViewModel.blockMeshPeer(peerID: person.peerID, displayName: person.nickname)
                        feedback = "Personne bloquée sur ce téléphone."
                    }
                    selected = nil
                }
            } message: {
                Text("\(selected.map { $0.nickname + " · " + String(($0.peerID.noiseKey?.sha256Fingerprint() ?? "").prefix(8)) } ?? "Cette personne") : ses prochains messages seront ignorés ici. L’historique existant reste sur ce téléphone.")
            }
    }
}

private struct WeshBlockedContacts: View {
    let runtime: AppRuntime
    @ObservedObject private var service: UnifiedPeerService
    @Environment(\.weshTheme) private var theme
    @State private var selectedFingerprint: String?
    @State private var feedback = ""

    init(runtime: AppRuntime) {
        self.runtime = runtime
        _service = ObservedObject(wrappedValue: runtime.chatViewModel.unifiedPeerService)
    }

    private var fingerprints: [String] { runtime.chatViewModel.identityManager.getBlockedFingerprints().sorted() }
    private func name(for fingerprint: String) -> String {
        let identity = runtime.chatViewModel.identityManager.getSocialIdentity(for: fingerprint)
        let name = identity?.localPetname ?? identity?.claimedNickname ?? ""
        return name.isEmpty ? "Personne sans nom" : name
    }

    var body: some View {
        List {
            Section {
                if fingerprints.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Personne n’est bloqué.").font(.title2.weight(.semibold))
                        Text("Les personnes bloquées apparaîtront ici, même hors connexion.").foregroundStyle(theme.secondary)
                    }.padding(.vertical, 24).listRowSeparator(.hidden)
                } else {
                    ForEach(fingerprints, id: \.self) { fingerprint in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name(for: fingerprint)).font(.headline)
                            Text("Identité · " + String(fingerprint.prefix(8))).font(.caption.monospaced()).foregroundStyle(theme.secondary)
                            Button("Débloquer") { selectedFingerprint = fingerprint }.frame(minHeight: 44)
                        }.padding(.vertical, 8)
                    }
                }
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } footer: { Text("Débloquer ne remplace pas une vérification QR. Les messages des autres téléphones ne sont pas modifiés.") }
            .listRowBackground(theme.canvas).listRowSeparatorTint(theme.line)
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .navigationTitle("Contacts bloqués").navigationBarTitleDisplayMode(.inline).weshCanvas(title: "Contacts bloqués")
            .alert("Débloquer cette personne ?", isPresented: Binding(get: { selectedFingerprint != nil }, set: { if !$0 { selectedFingerprint = nil } })) {
                Button("Annuler", role: .cancel) { selectedFingerprint = nil }
                Button("Débloquer") {
                    if let fingerprint = selectedFingerprint {
                        feedback = runtime.chatViewModel.unblockWeshIdentity(fingerprint) ? "Personne débloquée." : "Cette personne n’est plus bloquée."
                    }
                    selectedFingerprint = nil
                }
            } message: { Text("Débloquer \(selectedFingerprint.map { name(for: $0) + " · " + String($0.prefix(8)) } ?? "cette personne") ? Ses prochains messages pourront à nouveau apparaître sur ce téléphone.") }
    }
}

private struct WeshAppearanceSettings: View {
    @AppStorage("wesh.appearance.v1") private var appearance: WeshAppearance = .night
    @Environment(\.weshTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Une touche de métal.").font(.title2.weight(.semibold))
                ForEach(WeshAppearance.allCases) { choice in
                    let palette = WeshTheme(appearance: choice)
                    Button { appearance = choice } label: {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("wesh").font(.system(.title2, design: .rounded).weight(.bold))
                                Capsule().fill(palette.metalFill).frame(width: 44, height: 8)
                                Capsule().fill(palette.ink).frame(width: 30, height: 4)
                            }.foregroundStyle(palette.ink).frame(width: 96, height: 108)
                                .background(palette.canvas, in: RoundedRectangle(cornerRadius: palette.radius))
                                .overlay(RoundedRectangle(cornerRadius: palette.radius).strokeBorder(theme.line, lineWidth: 1))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(choice.title).font(.headline)
                                Text(choice.subtitle).font(.subheadline).foregroundStyle(theme.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: appearance == choice ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(theme.accent).accessibilityHidden(true)
                        }.foregroundStyle(theme.ink).padding(.vertical, 8)
                    }.buttonStyle(.plain).accessibilityAddTraits(appearance == choice ? .isSelected : [])
                }
                Text("Argent ou or, sur noir pur. Le QR reste noir sur blanc pour être facile à scanner.")
                    .font(.subheadline).foregroundStyle(theme.secondary)
            }.padding(theme.contentInset)
        }.navigationTitle("Apparence").navigationBarTitleDisplayMode(.inline).weshCanvas(title: "Apparence")
    }
}

private struct WeshProfileEditor: View {
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.weshTheme) private var theme
    @State private var nickname = ""
    @State private var feedback = ""
    var body: some View {
        Form {
            Section {
                TextField("Votre surnom", text: $nickname).onSubmit(save)
                Button("Enregistrer", action: save).frame(minHeight: 44)
                if !feedback.isEmpty { Text(feedback).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
            } header: { WeshSectionLabel(text: "Votre surnom") } footer: {
                Text("Ce surnom est visible dans le salon public. Il ne prouve pas votre identité.")
            }.listRowBackground(theme.canvas)
        }.scrollContentBackground(.hidden).navigationTitle("Votre profil").weshCanvas(title: "Votre profil")
            .onAppear { nickname = chrome.nickname }
    }
    private func save() {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255 else { feedback = "Choisissez un surnom plus court et non vide."; return }
        chrome.setNickname(value); chrome.validateAndSaveNickname(); nickname = chrome.nickname
        feedback = "Surnom enregistré."
    }
}

private struct WeshConnectionSettings: View {
    @EnvironmentObject private var chrome: AppChromeModel
    @EnvironmentObject private var peers: PeerListModel
    @Environment(\.weshTheme) private var theme
    var body: some View {
        Form {
            Section {
                Label(bluetoothSummary(chrome.bluetoothState), systemImage: "antenna.radiowaves.left.and.right")
                if chrome.bluetoothState == .unauthorized { Button("Autoriser le Bluetooth", action: openWeshSystemSettings).frame(minHeight: 44) }
                LabeledContent("Connexions", value: String(peers.connectedMeshPeerCount))
            } footer: {
                Text("Gardez Wesh ouvert sur les deux téléphones. Une connexion disponible ne confirme pas la réception d’un message.")
            }.listRowBackground(theme.canvas)
            Section {
                LabeledContent("Transport", value: "Bluetooth")
                LabeledContent("Passerelles Internet", value: "Désactivées")
            }.listRowBackground(theme.canvas)
        }.scrollContentBackground(.hidden).navigationTitle("Connexion").weshCanvas(title: "Connexion")
    }
}

private struct WeshPrivacySettings: View {
    let runtime: AppRuntime
    @ObservedObject private var trust = WeshQRTrust.shared
    @Environment(\.weshTheme) private var theme
    @State private var forgetContacts = false
    var body: some View {
        Form {
            Section {
                Text("Les vérifications QR concernent ce téléphone. Les notes de rendez-vous restent locales.")
                Text("Les participants peuvent conserver et relayer vos messages publics.").foregroundStyle(theme.secondary)
            }.listRowBackground(theme.canvas)
            Section {
                Button("Retirer les vérifications QR", role: .destructive) { forgetContacts = true }.frame(minHeight: 44)
            }.listRowBackground(theme.canvas)
        }.scrollContentBackground(.hidden).navigationTitle("Confidentialité").weshCanvas(title: "Confidentialité")
            .alert("Retirer les vérifications QR ?", isPresented: $forgetContacts) {
                Button("Annuler", role: .cancel) {}
                Button("Retirer", role: .destructive) { runtime.chatViewModel.removeAllWeshContacts() }
            } message: { Text("Pour écrire à ces contacts, vous devrez scanner à nouveau leur QR. Les messages existants restent sur ce téléphone.") }
    }
}

private struct WeshMeetingNote: View {
    @Environment(\.weshTheme) private var theme
    @AppStorage("wesh.meeting.title") private var title = ""
    @AppStorage("wesh.meeting.place") private var place = ""
    @AppStorage("wesh.meeting.note") private var note = ""
    @AppStorage("wesh.meeting.date") private var date = Date().timeIntervalSince1970
    @State private var clear = false
    var body: some View {
        Form {
            Section {
                Label("Une note pour vous", systemImage: "calendar").font(.headline)
                Text("Une note personnelle, conservée ici. Rien n’est envoyé à vos contacts.").foregroundStyle(theme.secondary)
            }.listRowBackground(theme.canvas)
            Section("Votre rendez-vous") {
                TextField("Titre", text: $title)
                TextField("Lieu ou repère", text: $place)
                DatePicker("Quand", selection: Binding(get: { Date(timeIntervalSince1970: date) }, set: { date = $0.timeIntervalSince1970 }))
                TextField("À retenir", text: $note, axis: .vertical).lineLimit(3...8)
            }.listRowBackground(theme.canvas)
            Section { Button("Effacer cette note", role: .destructive) { clear = true }.frame(minHeight: 44) }.listRowBackground(theme.canvas)
        }
        .scrollContentBackground(.hidden).weshCanvas(title: "Rendez-vous")
        .navigationTitle("Rendez-vous")
        .alert("Effacer votre note ?", isPresented: $clear) {
            Button("Annuler", role: .cancel) {}
            Button("Effacer", role: .destructive) { title = ""; place = ""; note = ""; date = Date().timeIntervalSince1970 }
        }
    }
}

private func openWeshSystemSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    #endif
}
