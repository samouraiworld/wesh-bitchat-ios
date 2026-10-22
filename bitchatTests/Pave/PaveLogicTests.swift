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
        #expect(theme.rgb(.bg) == PaveRGB(0x0B0B0A))
        #expect(PaveTheme(.jour).colorScheme == .light)
    }

    @Test func publicYellowIsIdenticalInBothThemes() {
        #expect(PaveTheme(.nuit).rgb(.publicFill) == PaveTheme(.jour).rgb(.publicFill))
    }
}
