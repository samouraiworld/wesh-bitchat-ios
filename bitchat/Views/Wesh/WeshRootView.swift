import BitFoundation
import CoreBluetooth
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

private enum WeshColor {
    static let accent = Color(red: 0.14, green: 0.37, blue: 0.79)
    #if os(iOS)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    #endif
}

struct WeshRootView: View {
    let runtime: AppRuntime
    var body: some View {
        TabView {
            NavigationStack { WeshInbox(runtime: runtime) }
                .tabItem { Label("Discussions", systemImage: "bubble.left.and.bubble.right") }
            NavigationStack { WeshMeetingNote() }
                .tabItem { Label("Rendez-vous", systemImage: "calendar") }
            NavigationStack { WeshSettings(runtime: runtime) }
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
        .tint(WeshColor.accent)
    }
}

private struct WeshInbox: View {
    let runtime: AppRuntime
    @EnvironmentObject private var peers: PeerListModel
    @EnvironmentObject private var inbox: PrivateInboxModel
    @EnvironmentObject private var verification: VerificationModel
    @EnvironmentObject private var chrome: AppChromeModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var addingContact = false

    private var contacts: [WeshQRTrust.Contact] {
        trust.contacts.filter { !runtime.chatViewModel.isPeerBlocked(runtime.chatViewModel.getShortIDForNoiseKey($0.peerID)) }
    }

    var body: some View {
        List {
            Section {
                Label(bluetoothSummary(chrome.bluetoothState), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline).foregroundStyle(.secondary)
                if chrome.bluetoothState == .unauthorized {
                    Button("Ouvrir les réglages de Wesh", action: openWeshSystemSettings).frame(minHeight: 44)
                }
            }
            Section {
                NavigationLink {
                    WeshConversation(runtime: runtime, peerID: nil, title: "Salon local")
                } label: {
                    HStack(spacing: 14) {
                        WeshAvatar(symbol: "antenna.radiowaves.left.and.right", color: .orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Salon local · Public").font(.headline)
                            Text("Canal public entre téléphones compatibles.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            } header: { Text("À proximité") } footer: {
                Text("Un salon ouvert. Les messages peuvent être relayés entre téléphones ; aucune frontière géographique garantie.")
            }
            Section {
                if contacts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vos proches, à portée de main").font(.headline)
                        Text("Scannez le QR d’une personne près de vous pour vérifier son identité sur ce téléphone.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { addingContact = true } label: { Label("Ajouter un contact", systemImage: "qrcode.viewfinder").frame(minHeight: 44) }
                    }.padding(.vertical, 8)
                } else {
                    ForEach(contacts) { row in
                        NavigationLink {
                            WeshConversation(runtime: runtime, peerID: row.peerID, title: row.nickname)
                        } label: {
                            HStack(spacing: 14) {
                                WeshAvatar(symbol: "person.fill", color: WeshColor.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.nickname).font(.headline)
                                    Text(inbox.messages(for: row.peerID).last?.content ?? "Identité vérifiée sur ce téléphone")
                                        .lineLimit(2).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if inbox.unreadPeerIDs.contains(row.peerID) || inbox.unreadPeerIDs.contains(runtime.chatViewModel.getShortIDForNoiseKey(row.peerID)) { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(WeshColor.accent).accessibilityLabel("Messages non lus") }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            } header: { Text("Messages privés") }
        }
        .navigationTitle("Wesh")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addingContact = true } label: { Label("Ajouter", systemImage: "person.badge.plus").frame(minHeight: 44) }
            }
        }
        .sheet(isPresented: $addingContact) { WeshContactSheet(runtime: runtime) }
    }
}

private struct WeshAvatar: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(color)
            .frame(width: 48, height: 48).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
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
    @State private var contactSheet = false
    @AppStorage("wesh.publicMuted") private var publicMuted = false
    @EnvironmentObject private var actions: ConversationUIModel
    @AppStorage("wesh.publicDisclosureAccepted.v1") private var publicAccepted = false
    @EnvironmentObject private var chrome: AppChromeModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool

    private var isPrivate: Bool { peerID != nil }
    private var draftKey: ComposerDraftStore.Key {
        .from(peerID: peerID, fingerprint: peerID?.noiseKey?.sha256Fingerprint(), channel: .mesh)
    }
    private var canSend: Bool { peerID.map { runtime.chatViewModel.canSendWeshPrivate(to: $0) } ?? runtime.chatViewModel.canSendWeshPublic }
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
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(isPrivate ? (canSend ? "Identité vérifiée sur ce téléphone" : "Écriture suspendue · connexion ou QR requis") : "Public · Bluetooth à proximité",
                                  systemImage: isPrivate ? "lock" : "antenna.radiowaves.left.and.right").font(.subheadline.weight(.medium))
                            Text(isPrivate ? "Pour échanger, chacun doit scanner le QR de l’autre sur son téléphone." : "Les participants peuvent voir, conserver et relayer vos messages. Les surnoms ne sont pas des identités vérifiées.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if isPrivate && !canSend {
                                Button("Vérifier ou reconnecter le contact") { contactSheet = true }.frame(minHeight: 44)
                                Text("Connexion sécurisée et QR du contact requis. Aucun message ne sera envoyé avant cette vérification.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if !isPrivate && !canSend {
                                Text(bluetoothSummary(chrome.bluetoothState)).font(.subheadline)
                                Text("Votre brouillon reste sur ce téléphone tant que le Bluetooth est indisponible.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if chrome.bluetoothState == .unauthorized {
                                    Button("Ouvrir les réglages de Wesh", action: openWeshSystemSettings).frame(minHeight: 44)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(WeshColor.surface)
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: isPrivate ? "bubble.left.and.bubble.right" : "antenna.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
                                Text(isPrivate ? "Votre conversation commence ici" : "Ouvrez la conversation autour de vous").font(.headline)
                                Text(isPrivate ? "Les messages privés utilisent la connexion chiffrée existante." : "Aucun contact ni QR nécessaire pour ce salon public.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 50)
                        }
                        ForEach(messages, id: \.id) { message in
                            WeshMessageBubble(message: message,
                                own: runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID, displayName: message.sender),
                                privateChat: isPrivate).id(message.id)
                                .contextMenu {
                                    if !runtime.chatViewModel.isSelfSender(peerID: message.senderPeerID, displayName: message.sender), message.sender != "system", let sender = message.senderPeerID {
                                        Button("Bloquer sur ce téléphone", role: .destructive) { actions.block(peerID: sender, displayName: message.sender) }
                                    }
                                }
                        }
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let id = messages.last?.id {
                        if reduceMotion { scroll.scrollTo(id, anchor: .bottom) }
                        else { withAnimation { scroll.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
        }
        .background(WeshColor.canvas)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField(isPrivate ? "Message privé" : "Message public", text: $draft, axis: .vertical)
                    .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                    .focused($composerFocused)
                    .padding(12).background(WeshColor.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(isPrivate ? "Message privé" : "Message public")
                Button {
                    if !isPrivate && !publicAccepted { publicWarning = true } else { send() }
                } label: { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 44, height: 44) }
                    .accessibilityLabel(isPrivate ? "Envoyer le message privé" : "Envoyer publiquement")
                    .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding().background(WeshColor.canvas)
        }
        .toolbar {
            if !isPrivate {
                ToolbarItem(placement: .primaryAction) {
                    Button { publicMuted.toggle() } label: { Label(publicMuted ? "Réactiver" : "Sourdine", systemImage: publicMuted ? "bell.slash" : "bell").frame(minHeight: 44) }
                }
            }
        }
        .alert("Envoyer dans un salon public ?", isPresented: $publicWarning) {
            Button("Annuler", role: .cancel) {}
            Button("Envoyer publiquement") { publicAccepted = true; send() }
        } message: { Text("Tout participant au salon peut voir, conserver ou relayer ce message. Le Bluetooth ne garantit aucune frontière géographique. Un surnom ne prouve pas une identité. Votre brouillon reste ici si vous annulez.") }
        .sheet(isPresented: $contactSheet) { WeshContactSheet(runtime: runtime) }
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

private struct WeshMessageBubble: View {
    let message: BitchatMessage
    let own: Bool
    let privateChat: Bool
    var body: some View {
        HStack {
            if own { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                if !own { Text(message.sender == "system" ? "Information" : message.sender).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(message.content).font(.body).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(message.timestamp, style: .time)
                    if own, privateChat { Text(WeshDelivery.label(message.deliveryStatus)) }
                    else if own { Text(WeshDelivery.publicLabel(message.deliveryStatus)) }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(12).background(own ? WeshColor.accent.opacity(0.12) : WeshColor.surface, in: RoundedRectangle(cornerRadius: 18))
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
    @EnvironmentObject private var verification: VerificationModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var scanning = false
    @State private var cameraUnavailable = false
    @State private var status = ""
    @State private var scannedKey: Data?
    @State private var qr = ""
    @State private var pastedQR = ""
    @FocusState private var pastedQRFocused: Bool
    @State private var progress: ChatVerificationCoordinator.QRProgress = .unavailable
    private let renewal = Timer.publish(every: 45, on: .main, in: .common).autoconnect()
    private let progressRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var completed: Bool {
        progress == .verified
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Vérifiez-vous en personne").font(.title2.weight(.bold))
                    Text("Montrez ce QR en direct sur votre écran, pas une photo. Puis scannez celui affiché en direct sur le téléphone de votre contact pour vérifier son identité sur ce téléphone.").foregroundStyle(.secondary)
                    if qr.isEmpty {
                        Text("Le QR sera disponible quand votre identité locale sera prête.").foregroundStyle(.secondary)
                    } else {
                        GeometryReader { geometry in
                            QRCodeImage(data: qr, size: min(216, max(120, geometry.size.width - 24))).padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20)).frame(maxWidth: .infinity)
                                .accessibilityLabel("Votre QR d’identité. Montrez-le en direct au contact que vous rencontrez.")
                        }.frame(height: 240)
                    }
                    Text("QR temporaire, renouvelé automatiquement. Vérification locale uniquement : ce téléphone ne peut pas confirmer ce que l’autre personne a vérifié.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if scanning {
                        CameraScannerView(isActive: scanning, onUnavailable: { cameraUnavailable = true; scanning = false }, onCode: scan)
                            .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityLabel("Scanner le QR du contact")
                        Button("Arrêter la caméra") { scanning = false }.frame(minHeight: 44)
                    } else {
                        Button { scanning = true; cameraUnavailable = false } label: {
                            Label("Scanner le QR du contact", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                    }
                    if cameraUnavailable { Text("Caméra indisponible. Autorisez la caméra dans les réglages du téléphone ou comparez le lien sur l’écran en direct de votre contact avant de le coller.").foregroundStyle(.secondary) }
                    DisclosureGroup("Comparer et coller un lien QR en direct") {
                        Text("Comparez ce lien sur le téléphone de la personne devant vous. Une photo ou un lien transféré ne prouve pas qui vous rencontrez.").font(.footnote)
                        TextField("Lien QR", text: $pastedQR, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                            .focused($pastedQRFocused)
                        Button("Vérifier ce QR") { scan(pastedQR) }.frame(minHeight: 44).disabled(pastedQR.isEmpty)
                    }
                    if completed {
                        Label("Identité vérifiée sur ce téléphone", systemImage: "checkmark.shield").foregroundStyle(.green)
                        Text("Demandez au contact de scanner votre QR sur son téléphone pour qu’il puisse vous écrire.").font(.subheadline)
                    } else if scannedKey != nil && (progress == .expired || progress == .unavailable) {
                        Text("Aucune confirmation reçue. Gardez Wesh ouvert sur les deux téléphones, puis scannez à nouveau.")
                            .font(.subheadline)
                        Button("Réessayer le scan") { scannedKey = nil; scanning = true; status = "" }.frame(minHeight: 44)
                    } else if !status.isEmpty { Text(status).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ajouter un contact").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() }.frame(minHeight: 44) } }
            .onAppear { qr = verification.myQRString() }
            .onReceive(renewal) { _ in qr = verification.myQRString() }
            .onReceive(progressRefresh) { _ in refreshProgress() }
            .onChange(of: trust.fingerprints) { _ in refreshProgress() }
        }
    }

    private func scan(_ value: String) {
        pastedQRFocused = false
        scanning = false
        scannedKey = nil
        progress = .unavailable
        switch verification.verifyScannedPayload(value) {
        case .invalid: status = "QR invalide ou expiré. Demandez un nouveau QR à votre contact."
        case .notFound: status = "Contact introuvable à proximité ou identité différente. Rapprochez les téléphones et réessayez."
        case .requested(let name):
            if let url = URL(string: value), let parsed = VerificationService.VerificationQR.fromURL(url) { scannedKey = Data(hexString: parsed.noiseKeyHex) }
            status = "Vérification de \(name) en cours sur la connexion sécurisée. Gardez les deux applications ouvertes."
            refreshProgress()
        }
    }

    private func refreshProgress() {
        guard let scannedKey else { return }
        progress = runtime.chatViewModel.weshQRProgress(for: scannedKey)
    }
}

private func bluetoothSummary(_ state: CBManagerState) -> String {
    switch state {
    case .poweredOn: return "Bluetooth actif · ouvrez Wesh sur les deux téléphones"
    case .poweredOff: return "Activez le Bluetooth pour échanger à proximité"
    case .unauthorized: return "Autorisez le Bluetooth dans les réglages du téléphone"
    case .unsupported: return "Bluetooth non disponible sur cet appareil"
    default: return "Préparation du Bluetooth…"
    }
}

private struct WeshSettings: View {
    let runtime: AppRuntime
    @EnvironmentObject private var chrome: AppChromeModel
    @EnvironmentObject private var peers: PeerListModel
    @ObservedObject private var trust = WeshQRTrust.shared
    @State private var nickname = ""
    @State private var forgetContacts = false
    @State private var showQR = false
    var body: some View {
        Form {
            Section("Votre profil") {
                TextField("Votre surnom", text: $nickname).onSubmit(saveNickname)
                Button("Enregistrer le surnom", action: saveNickname).frame(minHeight: 44)
                Button { showQR = true } label: { Label("Mon QR d’identité", systemImage: "qrcode").frame(minHeight: 44) }
                Text("Un surnom est public dans le salon local. Il ne prouve pas votre identité.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Prêt à échanger") {
                Label(bluetoothSummary(chrome.bluetoothState), systemImage: "antenna.radiowaves.left.and.right")
                if chrome.bluetoothState == .unauthorized { Button("Ouvrir les réglages de Wesh", action: openWeshSystemSettings).frame(minHeight: 44) }
                LabeledContent("Connexions Bluetooth", value: String(peers.connectedMeshPeerCount))
                Text("Une connexion indique une disponibilité, pas la réception d’un message. Pour le premier essai, gardez les deux applications au premier plan.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("Mode", value: "Bluetooth à proximité")
                LabeledContent("Passerelles Internet ici", value: "Désactivées")
                Text("Sourdine du salon : notifications de mentions désactivées. Le salon reste accessible. Pour bloquer un participant, maintenez son message appuyé.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Vos données sur ce téléphone") {
                Text("Les notes de rendez-vous restent locales. Les participants au salon peuvent conserver vos messages publics.").font(.subheadline)
                Button("Retirer les vérifications QR", role: .destructive) { forgetContacts = true }.frame(minHeight: 44)
            }
            Section { Text("Wesh · expérimentation native\nCompatibilité radio prévue après la première version.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Réglages")
        .onAppear { nickname = chrome.nickname }
        .alert("Retirer les vérifications QR ?", isPresented: $forgetContacts) {
            Button("Annuler", role: .cancel) {}
            Button("Retirer", role: .destructive) { trust.clear() }
        } message: { Text("Pour écrire à ces contacts, vous devrez scanner à nouveau leur QR. Les messages existants restent sur ce téléphone.") }
        .sheet(isPresented: $showQR) { WeshContactSheet(runtime: runtime) }
    }
    private func saveNickname() {
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 255 else { return }
        chrome.setNickname(value); chrome.validateAndSaveNickname(); nickname = chrome.nickname
    }
}

private struct WeshMeetingNote: View {
    @AppStorage("wesh.meeting.title") private var title = ""
    @AppStorage("wesh.meeting.place") private var place = ""
    @AppStorage("wesh.meeting.note") private var note = ""
    @AppStorage("wesh.meeting.date") private var date = Date().timeIntervalSince1970
    @State private var clear = false
    var body: some View {
        Form {
            Section {
                Label("Une note pour vous", systemImage: "calendar").font(.headline)
                Text("Préparez un rendez-vous. Cette note reste sur ce téléphone et n’est jamais envoyée automatiquement.").foregroundStyle(.secondary)
            }
            Section("Votre rendez-vous") {
                TextField("Titre", text: $title)
                TextField("Lieu ou repère", text: $place)
                DatePicker("Quand", selection: Binding(get: { Date(timeIntervalSince1970: date) }, set: { date = $0.timeIntervalSince1970 }))
                TextField("À retenir", text: $note, axis: .vertical).lineLimit(3...8)
            }
            Section { Button("Effacer cette note", role: .destructive) { clear = true }.frame(minHeight: 44) }
        }
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
