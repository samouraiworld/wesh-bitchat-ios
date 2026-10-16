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

    /// A poster style scaled with Dynamic Type relative to `textStyle`.
    static func font(size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font {
        isAvailable
            ? .custom(postScriptName, size: size, relativeTo: textStyle)
            : .system(size: size, weight: .black).width(.condensed)
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

extension Text {
    /// App copy in poster capitals. VoiceOver keeps reading the text as written.
    func paveDisplay(_ style: PaveDisplayStyle, label: String) -> some View {
        self.textCase(.uppercase)
            .font(style.font)
            .lineSpacing(-4)
            .accessibilityLabel(Text(verbatim: label))
    }
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
