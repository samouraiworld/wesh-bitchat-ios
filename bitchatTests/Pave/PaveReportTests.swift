import BitFoundation
import Foundation
import Testing
@testable import bitchat

@Suite("Report sent to the Wesh team")
struct PaveReportTests {
    private func mail(_ target: PaveReportTarget, _ reason: PaveReportReason = .harassment) -> PaveReportMail {
        PaveReportMail.compose(target, reason: reason)
    }

    private func field(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    @Test func theAddressIsDefinedOnce() throws {
        #expect(WeshLinks.reportEmail == "support@samourai.coop")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bitchat")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        let defining = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("samourai.coop") }
        #expect(defining.map(\.lastPathComponent) == ["WeshRequests.swift"])
        #expect(WeshLinks.terms.absoluteString == "https://wesh.samourai.app/conditions")
    }

    @Test func theDraftGoesToTheReportAddressWithTheFixedSubject() {
        let mail = mail(PaveReportTarget(rawNickname: "Léo", fingerprint: "3C81 E0F2 9A47 15BD", source: .contact))
        #expect(mail.url.scheme == "mailto")
        #expect(mail.url.absoluteString.hasPrefix("mailto:support@samourai.coop?subject="))
        #expect(field(mail.url, "subject") == "Signalement Wesh")
        #expect(mail.subject == "Signalement Wesh")
    }

    @Test func theNicknameGoesThroughTheRemoteNameRule() {
        let raw = "Le\u{200B}o"  // an invisible character between letters: shown as unnamed
        let body = mail(PaveReportTarget(rawNickname: raw, fingerprint: "3C81 E0F2 9A47 15BD", source: .request), .spam).body
        #expect(body.contains(PaveDisplayName.safe(raw)))
        #expect(!body.contains(raw))
        #expect(body.contains("3C81 E0F2 9A47 15BD"))
        #expect(body.contains(PaveReportReason.spam.label))
        #expect(body.contains(PaveCopy.text("pave.report.where.request")))
    }

    @Test func aMissingFingerprintSaysSo() {
        let body = mail(PaveReportTarget(rawNickname: "Léo", fingerprint: nil, source: .contact)).body
        #expect(body.contains(PaveCopy.text("pave.fingerprint.unavailable")))
    }

    @Test func onlyAPublicRoomMessageCarriesItsText() {
        let heading = PaveCopy.text("pave.report.mail.publicMessage")
        let publicBody = mail(PaveReportTarget(rawNickname: "Léo", fingerprint: nil, source: .publicMessage("Rendez-vous à 18 h & après ?"))).body
        #expect(publicBody.contains("Rendez-vous à 18 h & après ?"))
        #expect(publicBody.contains(heading))
        for source in [PaveReportSource.request, .contact] {
            #expect(!mail(PaveReportTarget(rawNickname: "Léo", fingerprint: nil, source: source)).body.contains(heading))
        }
    }

    @Test @MainActor func aRequestNeverCarriesItsPrivateMessages() {
        let key = Data(repeating: 0x42, count: 32)
        let secret = BitchatMessage(id: "r-1", sender: "Léo", content: "code porte 4521", timestamp: Date(), isRelay: false,
                                    originalSender: nil, isPrivate: true, recipientNickname: "Moi", senderPeerID: PeerID(hexData: key))
        let request = WeshInboundRequests.Request(noiseKey: key, nickname: "Léo", messages: [secret], receivedAt: Date())
        let target = PaveReportTarget.request(request)
        #expect(target == PaveReportTarget(rawNickname: "Léo", fingerprint: PaveFingerprint.short(key), source: .request))
        let mail = mail(target)
        #expect(!mail.body.contains("code porte 4521"))
        #expect(!(field(mail.url, "body") ?? "").contains("4521"))
    }

    @Test func subjectAndBodyArePercentEncoded() throws {
        let mail = mail(PaveReportTarget(rawNickname: "A&B=C?", fingerprint: "3C81 E0F2 9A47 15BD",
                                         source: .publicMessage("100 % + #tag\nligne 2")))
        let query = try #require(mail.url.absoluteString.split(separator: "?", maxSplits: 1).last.map(String.init))
        #expect(!query.contains(" ") && !query.contains("\n") && !query.contains("#") && !query.contains("+"))
        #expect(query.split(separator: "&").count == 2)  // the nickname's '&' and '=' cannot open a field
        #expect(query.contains("%0D%0A"))
        #expect(field(mail.url, "body") == mail.body.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    @Test func theLocalBlockRunsFirstAndTheAppSendsNothing() throws {
        var blocks = 0
        let target = PaveReportTarget(rawNickname: "Léo", fingerprint: nil, source: .contact)
        let first = PaveReportMail.blockThenOffer(target) { blocks += 1; return true }
        #expect(blocks == 1 && first.blocked && first.offer == target)
        let failed = PaveReportMail.blockThenOffer(target) { blocks += 1; return false }
        #expect(blocks == 2 && !failed.blocked && failed.offer == target)
        // The app hands an editable draft to the mail app; it opens no connection of its own.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("bitchat/Views/Wesh/Pave/PaveReport.swift"), encoding: .utf8)
        #expect(source.contains("openURL"))
        #expect(!source.contains("URLSession") && !source.contains("MFMailCompose"))
    }
    @Test func aQuotedPublicMessageCannotForgeFieldsOrHideText() throws {
        let reason = PaveCopy.text("pave.report.mail.reason", "")
        let fingerprint = PaveCopy.text("pave.report.mail.fingerprint", "")
        let place = PaveCopy.text("pave.report.mail.where", "")
        let forged = "salut\n\(reason)Spam\r\n\(fingerprint)0000 0000 0000 0000\u{2028}\(place)Contact\u{202E}esrever\u{200B}fin"
        let body = mail(PaveReportTarget(rawNickname: "Léo", fingerprint: "3C81 E0F2 9A47 15BD", source: .publicMessage(forged))).body
        for hidden in ["\u{202E}", "\u{200B}", "\u{2028}", "\r"] { #expect(!body.contains(hidden)) }
        let lines = body.components(separatedBy: "\n")
        for field in [reason, fingerprint, place] {
            #expect(lines.filter { $0.hasPrefix(field) }.count == 1, "\(field) forged")
        }
        let delimiter = try #require(lines.firstIndex(of: PaveReportMail.quoteDelimiter))
        #expect(delimiter > (lines.firstIndex { $0.hasPrefix(place) } ?? .max))
        #expect(lines[delimiter + 1] == PaveCopy.text("pave.report.mail.publicMessage"))
        #expect(Array(lines[(delimiter + 2)...]) == ["> salut", "> \(reason)Spam", "> \(fingerprint)0000 0000 0000 0000",
                                                     "> \(place)Contactesreverfin"])
    }

    @Test func aLongPublicMessageIsCappedAfterCleaningEveryLineQuoted() {
        let long = String(repeating: "a\u{200B}", count: 600) + "\n" + String(repeating: "b", count: 2_000)
        #expect(PaveReportMail.quote(long) == "> " + String(repeating: "a", count: 600) + "\n> " + String(repeating: "b", count: 399) + "…")
    }
}
