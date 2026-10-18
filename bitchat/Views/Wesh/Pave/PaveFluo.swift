import CoreText
import SwiftUI

// Pavé Fluo signatures: the poster face, the asphalt grain, the hazard stripes reserved for
// erasing, and the row of pavés that light up, one per phone in reach.

/// Archivo ExtraCondensed Black: a static OFL instance of Archivo 2.001 bundled with the app and
/// registered at first use. Never fetched online. Used only for app labels, never for nicknames or
/// message text (it covers Latin only and capitals would hide look-alike letters).
enum PaveDisplayFont {
    static let postScriptName = "Archivo-ExtraCondensedBlack"

    /// True once the bundled font is registered; when it is missing, the condensed system face is used.
    static let isAvailable: Bool = {
        let bundle = PaveCopy.bundle
        let url = bundle.url(forResource: "ArchivoExtraCondensedBlack", withExtension: "ttf", subdirectory: "Fonts")
            ?? bundle.url(forResource: "ArchivoExtraCondensedBlack", withExtension: "ttf")
        guard let url else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Already registered by an earlier launch path in the same process.
        return CTFontCreateWithName(postScriptName as CFString, 12, nil).postScriptName == postScriptName
    }()

    /// A poster style scaled with Dynamic Type relative to `textStyle`. The fallback follows
    /// Dynamic Type too, through the text style itself.
    static func font(size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        isAvailable
            ? .custom(postScriptName, size: size, relativeTo: textStyle)
            : .system(textStyle, design: .default).weight(.black).width(.condensed)
    }

    /// The SIL Open Font License shipped next to the font, shown in Licences.
    static func licenseText(in bundle: Bundle = PaveCopy.bundle) -> String? {
        let url = bundle.url(forResource: "Archivo-OFL", withExtension: "txt", subdirectory: "Fonts")
            ?? bundle.url(forResource: "Archivo-OFL", withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

/// Offline notices use the same bundle in the app and SwiftPM resource builds.
enum PaveLegalNotices {
    enum Component: String, CaseIterable, Identifiable {
        case secp256k1, arti, archivo

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .secp256k1: return "pave.about.notices.secp256k1"
            case .arti: return "pave.about.notices.arti"
            case .archivo: return "pave.about.notices.archivo"
            }
        }

        var sourceURL: URL {
            switch self {
            case .secp256k1:
                return URL(string: "https://github.com/samouraiworld/swift-secp256k1/tree/0a1a9f9031b6f86f92eb9b66ef8a6882af531e6f")!
            case .arti:
                return URL(string: "https://gitlab.torproject.org/tpo/core/arti")!
            case .archivo:
                return URL(string: "https://github.com/Omnibus-Type/Archivo")!
            }
        }

        func text(in bundle: Bundle = PaveCopy.bundle) throws -> String {
            let name: String
            let directory: String
            switch self {
            case .secp256k1: name = "secp256k1-NOTICES"; directory = "Notices"
            case .arti: name = "Arti-NOTICES"; directory = "Notices"
            case .archivo:
                guard let text = PaveDisplayFont.licenseText(in: bundle),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw PaveLegalNotices.ResourceError.missingOrEmpty }
                return text
            }
            return try PaveLegalNotices.text(name, fileExtension: "txt", directory: directory, in: bundle)
        }
    }

    static let secpCoreSourceURL = URL(string: "https://github.com/bitcoin-core/secp256k1/tree/70f149b9a1bf4ed3266f97774d0ae9577534bf40")!

    enum ResourceError: Error, Equatable { case missingOrEmpty, incompleteInventory }

    private struct Inventory: Decodable {
        struct Entry: Decodable {
            struct Notice: Decodable { let sha256: String }
            let name: String
            let version: String
            let notices: [Notice]
        }
        let unresolved: [String]
        let components: [Entry]
        let targets: [String: [String]]
    }

    static func requireCompleteInventory(in bundle: Bundle = PaveCopy.bundle) throws {
        let json = try text("NoticeInventory", fileExtension: "json", directory: "Notices", in: bundle)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
        let expected = Set(inventory.targets.values.flatMap { $0 })
        let actual = Set(inventory.components.map { "\($0.name)@\($0.version)" })
        let hasTexts = inventory.components.allSatisfy { entry in
            !entry.notices.isEmpty && entry.notices.allSatisfy { $0.sha256.count == 64 }
        }
        guard inventory.unresolved.isEmpty, inventory.targets.count == 5,
              !expected.isEmpty, actual == expected, actual.count == inventory.components.count, hasTexts
        else { throw ResourceError.incompleteInventory }
    }

    private static func text(_ name: String, fileExtension ext: String, directory: String, in bundle: Bundle) throws -> String {
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: directory)
            ?? bundle.url(forResource: name, withExtension: ext)
        guard let url else { throw ResourceError.missingOrEmpty }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResourceError.missingOrEmpty
        }
        return text
    }
}

struct PaveLicensesScreen: View {
    @Environment(\.paveTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s4) {
                Text(PaveCopy.text("pave.about.licensesTitle"))
                    .paveText(.title)
                    .accessibilityAddTraits(.isHeader)
                Text(PaveCopy.text("pave.about.licenseWesh")).paveText(.body)
                Text(PaveCopy.text("pave.about.licenseThirdParty")).paveText(.body)
                Text(PaveCopy.text("pave.about.licenseFont")).paveText(.body)
                ForEach(PaveLegalNotices.Component.allCases) { component in
                    NavigationLink {
                        PaveLicenseDetailScreen(component: component)
                    } label: {
                        Label(PaveCopy.text(component.titleKey), systemImage: "doc.text")
                            .paveText(.headline)
                    }
                }
            }
            .foregroundStyle(theme[.ink])
            .padding(PaveSpace.s4)
        }
        .paveScreenBackground()
    }
}

private struct PaveLicenseDetailScreen: View {
    let component: PaveLegalNotices.Component
    @Environment(\.paveTheme) private var theme
    @State private var notice: String?
    @State private var isUnavailable = false
    @State private var isIncomplete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaveSpace.s4) {
                Text(PaveCopy.text(component.titleKey)).paveText(.title)
                    .accessibilityAddTraits(.isHeader)
                Link(PaveCopy.text("pave.about.notices.source"), destination: component.sourceURL)
                    .paveText(.body)
                if component == .secp256k1 {
                    Link(PaveCopy.text("pave.about.notices.sourceCore"), destination: PaveLegalNotices.secpCoreSourceURL)
                        .paveText(.body)
                }
                if isIncomplete {
                    Text(PaveCopy.text("pave.about.notices.incomplete")).paveText(.body)
                        .foregroundStyle(theme[.warning])
                }
                if isUnavailable {
                    Text(PaveCopy.text("pave.about.notices.unavailable")).paveText(.body)
                        .foregroundStyle(theme[.warning])
                }
                if let notice {
                    Text(verbatim: notice).paveText(.caption)
                        .foregroundStyle(theme[.inkMuted])
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PaveSpace.s4)
        }
        .paveScreenBackground()
        .task {
            do { notice = try component.text() }
            catch { isUnavailable = true }
            if component == .arti {
                do { try PaveLegalNotices.requireCompleteInventory() }
                catch { isIncomplete = true }
            }
        }
    }
}

private extension CTFont {
    var postScriptName: String { CTFontCopyPostScriptName(self) as String }
}

/// Poster type roles. Always capitals, always app copy.
enum PaveDisplayStyle: CaseIterable {
    case wordmark, numeral, display, displaySmall

    var size: CGFloat {
        switch self {
        case .wordmark: return 56
        case .numeral: return 96
        case .display: return 44
        case .displaySmall: return 26
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .wordmark, .numeral: return .largeTitle
        case .display: return .title
        case .displaySmall: return .title3
        }
    }

    var font: Font { PaveDisplayFont.font(size: size, relativeTo: relativeTo) }
}

enum PaveFluo {
    /// Pavés in the reach gauge. More phones than this keep the row full.
    static let gaugePaves = 12
    static let meshStep: Double = 0.12
    static let meshMax: Double = 0.9
    /// The giant numeral follows Dynamic Type up to 1.3× its base size, then stops growing.
    static let maxNumeralScale: CGFloat = 1.3

    static func litPaves(_ phonesInReach: Int) -> Int { min(max(phonesInReach, 0), gaugePaves) }

    /// Seconds between two pavés lighting, so a full wave never exceeds `meshMax`.
    static func step(from: Int, to: Int) -> Double {
        let steps = abs(litPaves(to) - litPaves(from))
        guard steps > 0 else { return 0 }
        return min(meshStep, meshMax / Double(steps))
    }

    /// Whole wave length; zero with Reduce Motion.
    static func wave(from: Int, to: Int, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : step(from: from, to: to) * Double(abs(litPaves(to) - litPaves(from)))
    }

    static func numeralSize(scaled: CGFloat, base: CGFloat = PaveDisplayStyle.numeral.size) -> CGFloat {
        min(scaled, base * maxNumeralScale)
    }
}

/// Asphalt (Nuit) or poster-paper (Jour) grain: 1 pt dots every 4 pt, drawn once, never animated.
struct PaveGrain: View {
    @Environment(\.paveTheme) private var theme

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let dot = theme.id == .nuit ? Color.white.opacity(0.06) : Color.black.opacity(0.07)
            var path = Path()
            var y: CGFloat = 2
            while y < size.height {
                var x: CGFloat = 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                    x += 4
                }
                y += 4
            }
            context.fill(path, with: .color(dot))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 45° stripes, `danger` over `bg`. Only for what cannot be undone.
struct PaveHazard: View {
    @Environment(\.paveTheme) private var theme
    var band: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme[.bg]))
            var path = Path()
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + band, y: 0))
                path.addLine(to: CGPoint(x: x + band, y: size.height))
                path.closeSubpath()
                x += 2 * band
            }
            context.fill(path, with: .color(theme[.danger]))
        }
        .accessibilityHidden(true)
    }
}

/// Twelve pavés, one lit in `public` yellow per phone in reach. A change lights them one after
/// another in under 0.9 s; with Reduce Motion they change at once. Decorative: callers state the count.
struct PaveReachGauge: View {
    let phonesInReach: Int
    @Environment(\.paveTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<PaveFluo.gaugePaves, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < lit ? theme[.publicFill] : theme[.line])
                    .frame(height: 8)
            }
        }
        .accessibilityHidden(true)
        .task(id: phonesInReach) { await light(to: PaveFluo.litPaves(phonesInReach)) }
    }

    @MainActor
    private func light(to target: Int) async {
        let step = PaveFluo.step(from: lit, to: target)
        guard !reduceMotion, step > 0 else { lit = target; return }
        while lit != target {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: PaveMotion.stateChange)) { lit += lit < target ? 1 : -1 }
        }
    }
}

/// Home reach card: giant count, label, Bluetooth state and the gauge. VoiceOver reads one sentence.
struct PaveReachCard: View {
    let phonesInReach: Int
    let bluetoothOn: Bool
    @Environment(\.paveTheme) private var theme
    @ScaledMetric(relativeTo: .largeTitle) private var numeral: CGFloat = PaveDisplayStyle.numeral.size

    var body: some View {
        let count = max(phonesInReach, 0)
        HStack(alignment: .center, spacing: PaveSpace.s3) {
            Text(verbatim: "\(count)")
                .font(PaveDisplayFont.isAvailable
                    ? .custom(PaveDisplayFont.postScriptName, fixedSize: PaveFluo.numeralSize(scaled: numeral))
                    : .system(size: PaveFluo.numeralSize(scaled: numeral), weight: .black).width(.condensed))
                .foregroundStyle(theme[.ink])
            VStack(alignment: .leading, spacing: PaveSpace.s1) {
                Label(
                    PaveCopy.text(bluetoothOn ? "pave.fluo.bluetooth.on" : "pave.fluo.bluetooth.off"),
                    systemImage: bluetoothOn ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
                )
                .paveText(.caption)
                .foregroundStyle(bluetoothOn ? theme[.success] : theme[.warning])
                Text(count == 1 ? PaveCopy.text("pave.fluo.reach.one") : PaveCopy.text("pave.fluo.reach.other"))
                    .paveText(.headline)
                    .foregroundStyle(theme[.ink])
                PaveReachGauge(phonesInReach: count)
            }
        }
        .padding(.horizontal, PaveSpace.s4)
        .padding(.vertical, PaveSpace.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme[.surface], in: RoundedRectangle(cornerRadius: PaveRadius.control))
        .overlay(RoundedRectangle(cornerRadius: PaveRadius.control).stroke(theme[.line], lineWidth: PaveStroke.control))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PaveCopy.text(count == 1 ? "pave.fluo.reach.sentence.one" : "pave.fluo.reach.sentence.other", count)
            + ", " + PaveCopy.text(bluetoothOn ? "pave.fluo.bluetooth.on" : "pave.fluo.bluetooth.off")))
    }
}

#Preview("Reach card") {
    VStack(spacing: PaveSpace.s3) {
        PaveReachCard(phonesInReach: 7, bluetoothOn: true)
        PaveReachCard(phonesInReach: 0, bluetoothOn: false)
        PaveHazard().frame(height: 48)
    }
    .padding()
    .background(PaveGrain())
    .paveScreenBackground()
    .paveTheme(.nuit)
}
