import CoreBluetooth
import Foundation
import Testing
@testable import bitchat

struct PaveFluoTests {
    @Test func theGaugeLightsOnePavePerPhoneAndStaysFullBeyondTwelve() {
        #expect(PaveFluo.litPaves(-3) == 0)
        #expect(PaveFluo.litPaves(7) == 7)
        #expect(PaveFluo.litPaves(40) == 12)
    }

    @Test func aLightingWaveNeverExceedsNineTenthsOfASecondAndStopsWithReduceMotion() {
        #expect(abs(PaveFluo.wave(from: 0, to: 7, reduceMotion: false) - 0.84) < 0.0001)
        #expect(PaveFluo.wave(from: 0, to: 12, reduceMotion: false) <= PaveFluo.meshMax + 0.0001)
        #expect(PaveFluo.wave(from: 0, to: 12, reduceMotion: true) == 0)
        #expect(PaveFluo.wave(from: 4, to: 4, reduceMotion: false) == 0)
    }

    @Test func theGiantNumeralFollowsDynamicTypeUpToOnePointThreeOnly() {
        #expect(PaveFluo.numeralSize(scaled: 96) == 96)
        #expect(PaveFluo.numeralSize(scaled: 300) == 96 * 1.3)
    }

    @Test func theFluoYellowIsSharedAndNeverTextOnTheDayGround() {
        #expect(PaveTheme(.nuit).rgb(.publicFill) == PaveRGB(0xE4FF1A))
        #expect(PaveTheme(.jour).rgb(.publicFill).contrast(with: PaveTheme(.jour).rgb(.bg)) < 1.5)
        for id in PaveThemeID.allCases {
            let theme = PaveTheme(id)
            #expect(theme.rgb(.onPublic).contrast(with: theme.rgb(.publicFill)) >= 15)
            #expect(theme.rgb(.ink).contrast(with: theme.rgb(.bg)) >= 15)
            #expect(theme.rgb(.danger).contrast(with: theme.rgb(.bg)) >= 4.5)
        }
    }

    @Test func thePosterFaceShipsWithItsLicence() throws {
        let bundle = PaveCopy.bundle
        let font = bundle.url(forResource: "ArchivoExtraCondensedBlack", withExtension: "ttf", subdirectory: "Fonts")
            ?? bundle.url(forResource: "ArchivoExtraCondensedBlack", withExtension: "ttf")
        let licence = bundle.url(forResource: "Archivo-OFL", withExtension: "txt", subdirectory: "Fonts")
            ?? bundle.url(forResource: "Archivo-OFL", withExtension: "txt")
        #expect(font != nil)
        let text = try String(contentsOf: try #require(licence), encoding: .utf8)
        #expect(text.contains("SIL Open Font License"))
        #expect(PaveDisplayFont.isAvailable)
        // Shown in full in Licences, as the OFL asks of a bundled font.
        #expect(PaveDisplayFont.licenseText?.contains("SIL Open Font License") == true)
    }
}

struct PaveSettingsWiringTests {
    @Test @MainActor func aWipeFromSettingsShowsItsResultAndTheShortcutStillOpensTheHold() {
        let request = PaveEraseRequest()
        request.show(.erased)
        #expect(request.isPresented && request.outcome == .erased)
        request.close()
        request.show(.failed)
        #expect(request.outcome == .failed)
        request.close()
        request.request()
        #expect(request.isPresented && request.outcome == .ready)
    }

    @Test func onlyAPoweredOnRadioReadsAsOn() {
        #expect(PaveBluetoothStatus(CBManagerState.poweredOn) == .on)
        #expect(PaveBluetoothStatus(CBManagerState.unauthorized) == .unauthorized)
        for state in [CBManagerState.poweredOff, .unknown, .resetting, .unsupported] {
            #expect(PaveBluetoothStatus(state) == .off)
        }
    }

    @Test func theDiscretionRowReadsTheNotificationPreviewSetting() {
        let defaults = UserDefaults(suiteName: "pave.settings.\(UUID().uuidString)")!
        #expect(NotificationPrivacySettings.hideMessagePreviews(in: defaults))
        defaults.set(false, forKey: NotificationPrivacySettings.hidePreviewsKey)
        #expect(!NotificationPrivacySettings.hideMessagePreviews(in: defaults))
    }
}
