import Foundation
import SwiftUI

/// Reasons offered when the report is sent to the Wesh team.
enum PaveReportReason: String, CaseIterable, Identifiable {
    case harassment, illegal, spam, impersonation, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .harassment: return PaveCopy.text("pave.report.reason.harassment")
        case .illegal: return PaveCopy.text("pave.report.reason.illegal")
        case .spam: return PaveCopy.text("pave.report.reason.spam")
        case .impersonation: return PaveCopy.text("pave.report.reason.impersonation")
        case .other: return PaveCopy.text("pave.report.reason.other")
        }
    }
}

/// Where the person was met. Only a public room message carries text: everyone around could read it.
enum PaveReportSource: Equatable {
    case publicMessage(String)
    case request
    case contact
}

/// Who is reported: the nickname as received (shown only through the remote name rule) and the
/// short fingerprint.
struct PaveReportTarget: Equatable, Identifiable {
    let rawNickname: String?
    let fingerprint: String?
    let source: PaveReportSource

    var id: String { (fingerprint ?? "") + "|" + (rawNickname ?? "") }

    /// A request is reported by its nickname and fingerprint only, never its private messages.
    @MainActor static func request(_ request: WeshInboundRequests.Request) -> PaveReportTarget {
        PaveReportTarget(rawNickname: request.nickname, fingerprint: PaveFingerprint.short(request.noiseKey), source: .request)
    }
}

/// Copy shared with the moderation alerts outside the Pavé folder.
enum PaveReportCopy {
    static var localBlock: String { PaveCopy.text("pave.report.localBlock") }
    static var sendAction: String { PaveCopy.text("pave.report.send.action") }
}

/// The e-mail draft handed to the user's mail app, addressed to `WeshLinks.reportEmail`. It never
/// holds private message content, the user's keys or a location: only what `PaveReportTarget` carries.
struct PaveReportMail: Equatable {
    static let fixedSubject = "Signalement Wesh"
    /// Separates the fields written by the app from the quoted text written by someone else.
    static let quoteDelimiter = "-----"
    private static let maxPublicText = 1_000

    let subject: String
    let body: String
    let url: URL

    /// The local block always runs first, on its own; sending the report is then only offered,
    /// whether the block succeeded or not. Nothing is sent by the app.
    static func blockThenOffer(_ target: PaveReportTarget, block: () -> Bool) -> (blocked: Bool, offer: PaveReportTarget) {
        (block(), target)
    }

    static func compose(_ target: PaveReportTarget, reason: PaveReportReason) -> PaveReportMail {
        let whereKey: String
        var publicText: String?
        switch target.source {
        case .publicMessage(let text):
            whereKey = "pave.report.where.public"
            publicText = text
        case .request: whereKey = "pave.report.where.request"
        case .contact: whereKey = "pave.report.where.contact"
        }
        var lines = [
            PaveCopy.text("pave.report.mail.intro"),
            "",
            PaveCopy.text("pave.report.mail.nickname", PaveDisplayName.safe(target.rawNickname)),
            PaveCopy.text("pave.report.mail.fingerprint", target.fingerprint ?? PaveCopy.text("pave.fingerprint.unavailable")),
            PaveCopy.text("pave.report.mail.reason", reason.label),
            PaveCopy.text("pave.report.mail.where", PaveCopy.text(whereKey))
        ]
        // Last, after a delimiter, every line quoted: the text cannot pass for a field of the report.
        if let publicText {
            lines += ["", quoteDelimiter, PaveCopy.text("pave.report.mail.publicMessage"), quote(publicText)]
        }
        let body = lines.joined(separator: "\n")
        let link = "mailto:" + WeshLinks.reportEmail + "?subject=" + encode(fixedSubject)
            + "&body=" + encode(body.replacingOccurrences(of: "\n", with: "\r\n"))
        // Every character outside the unreserved set is escaped, so the URL always parses.
        return PaveReportMail(subject: fixedSubject, body: body, url: URL(string: link)!)
    }

    /// Someone else's text, made inert: line breaks unified, invisible and steering characters
    /// (bidi, zero-width, controls) removed, capped, then every line prefixed with "> ".
    static func quote(_ text: String) -> String {
        var cleaned = String.UnicodeScalarView()
        var pendingReturn = false
        for scalar in text.unicodeScalars {
            let isBreak = scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}"
            if isBreak {
                // "\r\n" is one break.
                if !(scalar == "\n" && pendingReturn) { cleaned.append("\n") }
                pendingReturn = scalar == "\r"
                continue
            }
            pendingReturn = false
            if !PaveDisplayName.isInvisible(scalar) { cleaned.append(scalar) }
        }
        var capped = String(cleaned)
        if capped.unicodeScalars.count > maxPublicText {
            capped = String(String.UnicodeScalarView(capped.unicodeScalars.prefix(maxPublicText))) + "…"
        }
        return capped.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
    }

    /// RFC 6068: every byte outside the unreserved set is percent-encoded, spaces included.
    static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// After the local block: offers to send the report to the Wesh team, by an e-mail the user reads,
/// edits and sends from their mail app. Without a mail app, shows the address and lets the user
/// copy it (local-only clipboard).
struct PaveReportSendFlow: ViewModifier {
    @Binding var target: PaveReportTarget?
    var onFinish: () -> Void = {}
    @Environment(\.openURL) private var openURL
    @State private var noMailApp = false

    func body(content: Content) -> some View {
        content
            .confirmationDialog(PaveReportCopy.sendAction,
                                isPresented: Binding(get: { target != nil }, set: { if !$0 { finishIfIdle() } }),
                                titleVisibility: .visible, presenting: target) { reported in
                ForEach(PaveReportReason.allCases) { reason in
                    Button(reason.label) { send(reported, reason) }
                }
                Button(PaveCopy.text("pave.action.cancel"), role: .cancel) { finishIfIdle() }
            } message: { _ in
                Text(PaveCopy.text("pave.report.send.body"))
            }
            .alert(PaveCopy.text("pave.report.noMail.title"), isPresented: $noMailApp) {
                Button(PaveCopy.text("pave.report.copyAddress")) { WeshPlatform.copy(WeshLinks.reportEmail); onFinish() }
                Button(PaveCopy.text("pave.action.close"), role: .cancel) { onFinish() }
            } message: {
                Text(PaveCopy.text("pave.report.noMail.body", WeshLinks.reportEmail))
            }
    }

    private func send(_ reported: PaveReportTarget, _ reason: PaveReportReason) {
        target = nil
        let mail = PaveReportMail.compose(reported, reason: reason)
        openURL(mail.url) { opened in
            if opened { onFinish() } else { noMailApp = true }
        }
    }

    private func finishIfIdle() {
        guard target != nil else { return }
        target = nil
        onFinish()
    }
}

extension View {
    func paveReportSendFlow(_ target: Binding<PaveReportTarget?>, onFinish: @escaping () -> Void = {}) -> some View {
        modifier(PaveReportSendFlow(target: target, onFinish: onFinish))
    }
}
