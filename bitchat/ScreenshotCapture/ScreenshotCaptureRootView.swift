#if WESH_SCREENSHOT_CAPTURE && os(iOS)
import SwiftUI

/// This marker is verified in Screenshot products and forbidden in Release products.
let weshScreenshotFixtureSentinel = "WESH_SCREENSHOT_FIXTURE_SENTINEL_V1"

enum WeshScreenshotScene: String, CaseIterable {
    case homePeers = "01-home-peers"
    case publicRoom = "02-public-room"
    case syntheticQR = "03-synthetic-qr"
    case verifiedPrivate = "04-verified-private"
    case unverifiedRequests = "05-unverified-requests"
    case frozenErase = "06-frozen-erase"
    case internetDisabled = "07-internet-disabled"

    static var selected: WeshScreenshotScene {
        ProcessInfo.processInfo.environment["WESH_SCREENSHOT_SCENE"]
            .flatMap(WeshScreenshotScene.init(rawValue:)) ?? .homePeers
    }
}

private enum ScreenshotLanguage: String {
    case en, fr

    static var selected: ScreenshotLanguage {
        let environment = ProcessInfo.processInfo.environment["WESH_SCREENSHOT_LOCALE"] ?? ""
        return environment.lowercased().hasPrefix("fr") ? .fr : .en
    }
}

private struct ScreenshotCopy {
    let language: ScreenshotLanguage

    func text(_ english: String, _ french: String) -> String {
        language == .fr ? french : english
    }
}

/// A deterministic, in-memory-only presentation layer. It does not construct AppRuntime,
/// Bluetooth, Tor, persistence, notifications, identity or networking services.
struct ScreenshotCaptureRootView: View {
    private let scene = WeshScreenshotScene.selected
    private let copy = ScreenshotCopy(language: .selected)

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                screenshotStatusBar
                sceneBody
                    .frame(
                        width: geometry.size.width,
                        height: max(geometry.size.height - 54, 0),
                        alignment: .top
                    )
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Color(red: 0.035, green: 0.035, blue: 0.04).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .accessibilityIdentifier("wesh-screenshot-\(scene.rawValue)")
        .accessibilityHint(weshScreenshotFixtureSentinel)
    }

    private var screenshotStatusBar: some View {
        HStack(spacing: 10) {
            Text("09:41")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Spacer()
            Image(systemName: "cellularbars")
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 24)
        .frame(height: 54)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(100)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var sceneBody: some View {
        switch scene {
        case .homePeers: homePeers
        case .publicRoom: publicRoom
        case .syntheticQR: syntheticQR
        case .verifiedPrivate: verifiedPrivate
        case .unverifiedRequests: unverifiedRequests
        case .frozenErase: frozenErase
        case .internetDisabled: internetDisabled
        }
    }

    private var homePeers: some View {
        chrome(title: "WESH") {
            VStack(alignment: .leading, spacing: 22) {
                countCard(count: 3, title: copy.text("phones nearby", "téléphones à portée"))
                section(copy.text("Nearby", "À proximité"))
                publicCard
                peerRow(name: "Maya", detail: copy.text("Verified contact", "Contact vérifié"), color: .cyan)
                peerRow(name: "Noé", detail: copy.text("Nearby now", "À proximité maintenant"), color: .mint)
                Spacer()
                primaryButton(copy.text("ADD A CONTACT", "AJOUTER UN CONTACT"), icon: "qrcode.viewfinder")
            }
        }
    }

    private var publicRoom: some View {
        conversationChrome(title: copy.text("LOCAL ROOM", "SALON LOCAL"), subtitle: copy.text("Public · Relayable messages", "Public · Messages relayables")) {
            VStack(spacing: 18) {
                dateDivider
                message(author: "Maya", text: copy.text("Hello from the local mesh 👋", "Salut depuis le réseau local 👋"), outgoing: false, color: .cyan)
                message(author: nil, text: copy.text("No mobile network needed.", "Pas besoin de réseau mobile."), outgoing: true, color: .white)
                message(author: "Noé", text: copy.text("Message relayed nearby ✓", "Message relayé à proximité ✓"), outgoing: false, color: .mint)
                Spacer()
                composer(copy.text("Public message", "Message public"))
            }
        }
    }

    private var syntheticQR: some View {
        chrome(title: copy.text("ADD A CONTACT", "AJOUTER UN CONTACT"), back: true) {
            VStack(spacing: 28) {
                Text(copy.text("A QR. Then you can talk.", "Un QR. Et on se parle."))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(copy.text("This one-time code verifies the person in front of you.", "Ce code à usage unique vérifie la personne en face de vous."))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                SyntheticQRView()
                    .padding(20)
                    .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .frame(maxWidth: 360)
                Label(copy.text("Synthetic non-scannable preview", "Aperçu synthétique non scannable"), systemImage: "checkmark.shield")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(copy.text("Renews in 42 seconds", "Se renouvelle dans 42 secondes"))
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.86, green: 1, blue: 0))
                Spacer()
            }
        }
    }

    private var verifiedPrivate: some View {
        conversationChrome(title: "MAYA", subtitle: copy.text("Verified · Private", "Vérifiée · Privé"), verified: true) {
            VStack(spacing: 18) {
                dateDivider
                message(author: "Maya", text: copy.text("Are you nearby?", "Tu es dans le coin ?"), outgoing: false, color: .cyan)
                message(author: nil, text: copy.text("Yes — meet by the entrance.", "Oui — rendez-vous à l’entrée."), outgoing: true, color: .white, status: copy.text("Delivered", "Livré"))
                message(author: "Maya", text: copy.text("Perfect, see you soon!", "Parfait, à tout de suite !"), outgoing: false, color: .cyan)
                Spacer()
                composer(copy.text("Private message", "Message privé"))
            }
        }
    }

    private var unverifiedRequests: some View {
        chrome(title: copy.text("MESSAGE REQUESTS", "DEMANDES DE MESSAGES"), back: true) {
            VStack(alignment: .leading, spacing: 20) {
                Text(copy.text("Unknown people stay separate until you decide.", "Les inconnus restent à part jusqu’à votre décision."))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                requestCard(name: copy.text("Nearby person 14", "Personne proche 14"), preview: copy.text("Hi, is this seat free?", "Salut, cette place est libre ?"), count: 2)
                requestCard(name: copy.text("Nearby person 27", "Personne proche 27"), preview: copy.text("Hello from the local mesh", "Bonjour depuis le réseau local"), count: 1)
                privacyCard
                Spacer()
            }
        }
    }

    private var frozenErase: some View {
        chrome(title: copy.text("SETTINGS", "RÉGLAGES")) {
            VStack(spacing: 22) {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 9)
                        Circle().trim(from: 0, to: 0.68)
                            .stroke(Color(red: 1, green: 0.29, blue: 0.25), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "flame.fill").font(.system(size: 30, weight: .black)).foregroundStyle(Color(red: 1, green: 0.29, blue: 0.25))
                    }
                    .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(copy.text("HOLD TO ERASE EVERYTHING", "MAINTENIR POUR TOUT EFFACER"))
                            .font(.system(size: 21, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.29, blue: 0.25))
                        Text(copy.text("Messages, contacts, keys and drafts on this phone.", "Messages, contacts, clés et brouillons de ce téléphone."))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                }
                .padding(22)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(red: 1, green: 0.29, blue: 0.25), lineWidth: 2))
                settingsRow(icon: "person.crop.circle", title: copy.text("Profile", "Profil"), value: "Pinson 29")
                settingsRow(icon: "antenna.radiowaves.left.and.right", title: copy.text("Connection", "Connexion"), value: copy.text("Bluetooth · Internet", "Bluetooth · Internet"))
                settingsRow(icon: "eye.slash", title: copy.text("Privacy", "Discrétion"), value: copy.text("Previews hidden", "Aperçus masqués"))
                settingsRow(icon: "hand.raised", title: copy.text("Blocked", "Bloqués"), value: "0")
                Spacer()
            }
        }
    }

    private var internetDisabled: some View {
        chrome(title: copy.text("CONNECTION", "CONNEXION"), back: true) {
            VStack(alignment: .leading, spacing: 24) {
                connectionCard(icon: "antenna.radiowaves.left.and.right", title: "Bluetooth", detail: copy.text("Active · local mesh only", "Actif · réseau local uniquement"), enabled: true)
                connectionCard(icon: "globe", title: "Internet", detail: copy.text("Disabled by default", "Désactivé par défaut"), enabled: false)
                VStack(alignment: .leading, spacing: 12) {
                    Label(copy.text("Your choice, every time", "Votre choix, à chaque fois"), systemImage: "lock.shield")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                    Text(copy.text("Wesh works nearby without mobile data. Internet stays off until you read the notice and enable it.", "Wesh fonctionne à proximité sans données mobiles. Internet reste coupé tant que vous n’avez pas lu l’avis et choisi de l’activer."))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(24)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                Spacer()
                primaryButton(copy.text("KEEP INTERNET OFF", "GARDER INTERNET COUPÉ"), icon: "checkmark")
            }
        }
    }

    private func chrome<Content: View>(title: String, back: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                if back {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 23, weight: .black))
                        .fixedSize()
                }
                Text(title)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                Text("W").font(.system(size: 24, weight: .black, design: .rounded))
                    .frame(width: 48, height: 48).background(.white).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 14))
                    .fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider().overlay(.white.opacity(0.25))
            content().padding(24)
        }
    }

    private func conversationChrome<Content: View>(title: String, subtitle: String, verified: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "chevron.left").font(.system(size: 23, weight: .black))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 26, weight: .black, design: .rounded))
                        if verified { Image(systemName: "checkmark.shield.fill").foregroundStyle(.mint) }
                    }
                    Text(subtitle).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Image(systemName: "ellipsis").font(.system(size: 22, weight: .black)).frame(width: 48, height: 48)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            Divider().overlay(.white.opacity(0.25))
            content().padding(24)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.6))
    }

    private func countCard(count: Int, title: String) -> some View {
        HStack(spacing: 18) {
            Text("\(count)").font(.system(size: 72, weight: .black, design: .rounded))
            VStack(alignment: .leading, spacing: 6) {
                Label(copy.text("Bluetooth active", "Bluetooth actif"), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.mint)
                Text(title).font(.system(size: 26, weight: .black, design: .rounded))
                HStack(spacing: 5) { ForEach(0..<9, id: \.self) { index in Capsule().fill(index < count ? Color(red: 0.86, green: 1, blue: 0) : .white.opacity(0.15)).frame(height: 9) } }
            }
        }
        .padding(22).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.24), lineWidth: 2))
    }

    private var publicCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "megaphone.fill").font(.system(size: 26, weight: .black))
            VStack(alignment: .leading, spacing: 5) {
                Text(copy.text("LOCAL ROOM", "SALON LOCAL")).font(.system(size: 27, weight: .black, design: .rounded))
                Text(copy.text("Public · open nearby conversation", "Public · une conversation ouverte autour de vous")).font(.system(size: 16, weight: .bold))
            }
            Spacer(); Image(systemName: "chevron.right")
        }
        .foregroundStyle(.black).padding(22).background(Color(red: 0.86, green: 1, blue: 0), in: RoundedRectangle(cornerRadius: 24))
    }

    private func peerRow(name: String, detail: String, color: Color) -> some View {
        HStack(spacing: 16) {
            Circle().fill(color).frame(width: 54, height: 54).overlay(Text(String(name.prefix(1))).font(.system(size: 23, weight: .black)).foregroundStyle(.black))
            VStack(alignment: .leading, spacing: 5) { Text(name).font(.system(size: 20, weight: .bold)); Text(detail).foregroundStyle(.white.opacity(0.58)) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.55))
        }.padding(.vertical, 6)
    }

    private var dateDivider: some View {
        HStack { line; Text(copy.text("Today", "Aujourd’hui")).font(.caption.bold()).foregroundStyle(.white.opacity(0.5)); line }
    }

    private var line: some View { Rectangle().fill(.white.opacity(0.18)).frame(height: 1) }

    private func message(author: String?, text: String, outgoing: Bool, color: Color, status: String? = nil) -> some View {
        HStack {
            if outgoing { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 7) {
                if let author { Text(author).font(.system(size: 14, weight: .bold)).foregroundStyle(color) }
                Text(text).font(.system(size: 19, weight: .medium))
                HStack { Text("09:41"); if let status { Text("· \(status)") } }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.48))
            }
            .padding(18).background(.white.opacity(outgoing ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.32), lineWidth: 1.5))
            if !outgoing { Spacer(minLength: 70) }
        }
    }

    private func composer(_ prompt: String) -> some View {
        HStack { Text(prompt).foregroundStyle(.white.opacity(0.45)); Spacer(); Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)) }
            .font(.system(size: 18, weight: .medium)).padding(.horizontal, 18).frame(height: 58).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.5), lineWidth: 1.5))
    }

    private func requestCard(name: String, preview: String, count: Int) -> some View {
        HStack(spacing: 16) {
            ZStack { Circle().fill(.white.opacity(0.09)); Image(systemName: "person.fill.questionmark").font(.system(size: 24, weight: .bold)) }.frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 6) { Text(name).font(.system(size: 19, weight: .bold)); Text(preview).lineLimit(1).foregroundStyle(.white.opacity(0.62)) }
            Spacer(); Text("\(count)").font(.system(size: 15, weight: .black)).foregroundStyle(.black).frame(width: 28, height: 28).background(Color(red: 0.86, green: 1, blue: 0), in: Circle())
        }.padding(20).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.22), lineWidth: 1.5))
    }

    private var privacyCard: some View {
        Label(copy.text("No notification or receipt is sent before you accept.", "Aucune notification ni accusé n’est envoyé avant votre accord."), systemImage: "hand.raised.fill")
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white.opacity(0.68)).padding(20).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20))
    }

    private func settingsRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 15) { Image(systemName: icon).frame(width: 28); Text(title).font(.system(size: 19, weight: .semibold)); Spacer(); Text(value).foregroundStyle(.white.opacity(0.55)); Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.35)) }
            .padding(.horizontal, 20).frame(height: 68).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }

    private func connectionCard(icon: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 26, weight: .bold)).frame(width: 48, height: 48).background(.white.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 22, weight: .bold)); Text(detail).foregroundStyle(.white.opacity(0.58)) }
            Spacer()
            Text(enabled ? copy.text("ON", "OUI") : copy.text("OFF", "NON")).font(.system(size: 14, weight: .black)).foregroundStyle(enabled ? .black : .white.opacity(0.62)).padding(.horizontal, 13).padding(.vertical, 8).background(enabled ? Color.mint : .white.opacity(0.1), in: Capsule())
        }.padding(22).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.22), lineWidth: 1.5))
    }

    private func primaryButton(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 21, weight: .black, design: .rounded)).frame(maxWidth: .infinity, minHeight: 62).foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct SyntheticQRView: View {
    private static let modules = 29
    private static let seed = Array("WESH-SYNTHETIC-NON-SCANNABLE-107".utf8)

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width, size.height) / CGFloat(Self.modules)
            for row in 0..<Self.modules {
                for column in 0..<Self.modules where filled(row: row, column: column) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: ceil(cell), height: ceil(cell))), with: .color(.black))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Synthetic non-scannable QR artwork")
    }

    private func filled(row: Int, column: Int) -> Bool {
        if finder(row: row, column: column, originRow: 1, originColumn: 1) { return true }
        if finder(row: row, column: column, originRow: 1, originColumn: 21) { return true }
        if finder(row: row, column: column, originRow: 21, originColumn: 1) { return true }
        let seedIndex = (row + column) % Self.seed.count
        let seedValue = Int(Self.seed[seedIndex])
        let index = (row * 31 + column * 17 + seedValue) % 11
        return index == 0 || index == 2 || index == 5 || (row + column).isMultiple(of: 13)
    }

    private func finder(row: Int, column: Int, originRow: Int, originColumn: Int) -> Bool {
        let y = row - originRow, x = column - originColumn
        guard (0..<7).contains(y), (0..<7).contains(x) else { return false }
        return y == 0 || y == 6 || x == 0 || x == 6 || ((2...4).contains(y) && (2...4).contains(x))
    }
}
#endif
