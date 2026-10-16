import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Pavé message budget")
struct PaveMessageBudgetTests {
    @Test func limitIsTheSharedWeshAdmissionBound() {
        #expect(PaveMessageBudget.maximumBytes == WeshTextLimits.maximumUTF8Bytes)
        #expect(PaveMessageBudget.maximumBytes == 2000)
    }

    @Test func counterAppearsOnlyPast1800Bytes() {
        #expect(!PaveMessageBudget(String(repeating: "a", count: 1800)).showsCounter)
        #expect(PaveMessageBudget(String(repeating: "a", count: 1801)).showsCounter)
    }

    @Test func countsUTF8BytesNotCharacters() {
        // « é » is two bytes: 901 of them cross the 1,800-byte threshold.
        let accented = String(repeating: "é", count: 901)
        #expect(accented.count == 901)
        #expect(PaveMessageBudget(accented).usedBytes == 1802)
        #expect(PaveMessageBudget(accented).showsCounter)
    }

    @Test func overLimitBlocksSending() {
        let atLimit = String(repeating: "a", count: 2000)
        let overLimit = atLimit + "a"
        #expect(!PaveMessageBudget(atLimit).isOverLimit)
        #expect(PaveMessageBudget.canSend(atLimit))
        #expect(PaveMessageBudget(overLimit).isOverLimit)
        #expect(!PaveMessageBudget.canSend(overLimit))
    }

    @Test func blankTextCannotBeSent() {
        #expect(!PaveMessageBudget.canSend(""))
        #expect(!PaveMessageBudget.canSend("  \n "))
        #expect(PaveMessageBudget.canSend(" ok "))
    }
}

@Suite("Pavé delivery states")
struct PaveDeliveryStateTests {
    private let now = Date(timeIntervalSince1970: 0)

    @Test func privateStatusesMapToTheFourStates() {
        #expect(PaveDeliveryState(.notSentYet, isPrivate: true) == .waiting)
        #expect(PaveDeliveryState(.sending, isPrivate: true) == .waiting)
        #expect(PaveDeliveryState(.sent, isPrivate: true) == .sent)
        #expect(PaveDeliveryState(.carried, isPrivate: true) == .sent)
        #expect(PaveDeliveryState(.partiallyDelivered(reached: 1, total: 3), isPrivate: true) == .sent)
        #expect(PaveDeliveryState(.delivered(to: "Nora", at: now), isPrivate: true) == .received)
        #expect(PaveDeliveryState(.failed(reason: "x"), isPrivate: true) == .failed)
    }

    @Test func readReceiptsAreNeverShownSeparately() {
        #expect(PaveDeliveryState(.read(by: "Nora", at: now), isPrivate: true) == .received)
    }

    @Test func publicMessagesNeverClaimReception() {
        #expect(PaveDeliveryState(.delivered(to: "x", at: now), isPrivate: false) == .sent)
        #expect(PaveDeliveryState(.read(by: "x", at: now), isPrivate: false) == .sent)
    }

    @Test func deliveryTokensAliasTheirBaseRoles() {
        #expect(PaveTheme.deliveryRole(.waiting) == .inkMuted)
        #expect(PaveTheme.deliveryRole(.sent) == .ink)
        #expect(PaveTheme.deliveryRole(.received) == .success)
        #expect(PaveTheme.deliveryRole(.failed) == .danger)
    }
}

@Suite("Pavé status pill")
struct PaveConnectionStatusTests {
    @Test func statusPillResolvesItsFourStates() {
        #expect(PaveConnectionStatus(bluetoothOn: true, peersInRange: 7, internetActive: false) == .inRange(7))
        #expect(PaveConnectionStatus(bluetoothOn: true, peersInRange: 0, internetActive: false) == .nobodyInRange)
        #expect(PaveConnectionStatus(bluetoothOn: false, peersInRange: 3, internetActive: false) == .bluetoothOff)
        #expect(PaveConnectionStatus(bluetoothOn: true, peersInRange: 3, internetActive: true) == .internet(inRange: 3))
        #expect(PaveConnectionStatus(bluetoothOn: false, peersInRange: 3, internetActive: true) == .internet(inRange: 0))
    }
}

@Suite("Pavé palette contrast")
struct PavePaletteContrastTests {
    @Test(arguments: PaveThemeID.allCases)
    func textReachesNormalContrast(_ id: PaveThemeID) {
        let theme = PaveTheme(id)
        let pairs: [(PaveColorRole, PaveColorRole)] = [
            (.ink, .bg), (.ink, .surface), (.ink, .surfaceRaised),
            (.inkMuted, .bg), (.inkMuted, .surface), (.inkMuted, .surfaceRaised),
            (.onPublic, .publicFill), (.onPrivate, .privateFill),
            (.onInternet, .internet), (.onDanger, .danger),
            (.danger, .bg), (.danger, .surface), (.success, .bg), (.success, .surface),
            (.warning, .bg), (.warning, .surface), (.internet, .bg), (.internet, .surface)
        ]
        for (foreground, background) in pairs {
            let ratio = theme.rgb(foreground).contrast(with: theme.rgb(background))
            #expect(ratio >= 4.5, "\(id) \(foreground) on \(background) is \(ratio):1")
        }
    }

    @Test(arguments: PaveThemeID.allCases)
    func controlBordersReachNonTextContrast(_ id: PaveThemeID) {
        let theme = PaveTheme(id)
        for background in [PaveColorRole.bg, .surface] {
            let ratio = theme.rgb(.lineStrong).contrast(with: theme.rgb(background))
            #expect(ratio >= 3, "\(id) line-strong on \(background) is \(ratio):1")
        }
        #expect(theme.rgb(.focus).contrast(with: theme.rgb(.bg)) >= 3)
    }

    @Test func nuitIsTheDefaultAndKeepsAnOLEDBlack() {
        let theme = PaveTheme()
        #expect(theme.id == .nuit)
        #expect(theme.colorScheme == .dark)
        #expect(theme.rgb(.bg) == PaveRGB(0x0A0A0A))
        #expect(PaveTheme(.jour).colorScheme == .light)
    }

    @Test func publicYellowIsIdenticalInBothThemes() {
        #expect(PaveTheme(.nuit).rgb(.publicFill) == PaveTheme(.jour).rgb(.publicFill))
    }
}

@Suite("Pavé display name sanitizer")
struct PaveDisplayNameTests {
    @Test func ordinaryNicknamesPassThrough() {
        #expect(PaveDisplayName.safe("Renard 42") == "Renard 42")
        #expect(PaveDisplayName.safe("Léo 17") == "Léo 17")
        #expect(PaveDisplayName.safe("Coquelicot") == "Coquelicot")
    }

    @Test func stripsBidiControlsAndZeroWidthCharacters() {
        // RLO, LRI/PDI, ZWSP, ZWJ, LRM: all Cf, none may survive.
        let hostile = "\u{202E}Nora\u{202C} \u{2066}x\u{2069}\u{200B}\u{200D}\u{200E}"
        let safe = PaveDisplayName.safe(hostile)
        #expect(safe == "Nora x")
        #expect(!safe.unicodeScalars.contains { $0.properties.generalCategory == .format })
    }

    @Test func stripsControlsAndLineBreaksSoNamesStayOnOneLine() {
        #expect(PaveDisplayName.safe("Nora\nVérifié") == "NoraVérifié")
        #expect(PaveDisplayName.safe("Nora\u{2028}\u{2029}\t\u{0007}") == "Nora")
    }

    @Test func appliesNFKCSoLookalikeFormsCollapse() {
        // Fullwidth letters and the ﬁ ligature fold to their plain forms.
        #expect(PaveDisplayName.safe("Ｎｏｒａ") == "Nora")
        #expect(PaveDisplayName.safe("\u{FB01}nch") == "finch")
        // Decomposed accents compose: one grapheme, no stray mark.
        #expect(PaveDisplayName.safe("Le\u{0301}o") == "Léo")
    }

    @Test func collapsesStackedCombiningMarks() {
        let zalgo = "N" + String(repeating: "\u{0336}\u{0337}\u{0338}\u{0489}", count: 20) + "ora"
        let safe = PaveDisplayName.safe(zalgo)
        let marks = safe.unicodeScalars.filter {
            [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory)
        }
        #expect(marks.count <= PaveDisplayName.maximumCombiningMarks)
        #expect(safe.hasSuffix("ora"))
        // A mark cannot start the name or hang off a space.
        #expect(PaveDisplayName.safe("\u{0301}\u{0301}Nora") == "Nora")
    }

    @Test func collapsesWhitespaceAndClampsLength() {
        #expect(PaveDisplayName.safe("  Nora \u{00A0}\u{3000}  42  ") == "Nora 42")
        let long = String(repeating: "x", count: 200)
        let safe = PaveDisplayName.safe(long)
        #expect(safe.count == PaveDisplayName.maximumGraphemes)
        #expect(safe.hasSuffix("…"))
        #expect(PaveDisplayName.safe(String(repeating: "y", count: 32)).count == 32)
    }

    @Test func emptyOrInvisibleNamesGetAPlaceholder() {
        let placeholder = PaveDisplayName.safe("")
        #expect(!placeholder.isEmpty)
        #expect(PaveDisplayName.safe("\u{200B}\u{202E} \n") == placeholder)
    }

    @Test func spoofedBadgeTextStaysPlainNameText() {
        // The badge is a symbol outside the name; whatever the name says, it is clamped text.
        let safe = PaveDisplayName.safe("\u{202E}Nora ✓ Vérifié\n" + String(repeating: "x", count: 40))
        #expect(safe.count <= PaveDisplayName.maximumGraphemes)
        #expect(!safe.contains("\n"))
        #expect(!safe.unicodeScalars.contains("\u{202E}"))
    }
}
