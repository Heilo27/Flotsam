import Foundation
import Testing
@testable import FlotsamBase

// FRD-000 section 7 as literals (OC-0005, OC-0057...OC-0065). Expected side is literals only: no production symbol
// computes any value here. `{limit}` and `{n}` stand for the catalogue placeholders `%@` and `%lld`.
private typealias Row = (code: String, severity: ErrorSeverity, message: String?)

private let section7: [Row] = [
    ("SYS-INT-001", .error, "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."),
    ("CAP-PRM-001", .warning, "macOS is blocking Flotsam from reading copied items. Allow Flotsam under Paste from Other Apps in System Settings."),
    ("CAP-OS-001", .warning, "Flotsam couldn't read the clipboard just now. It will keep trying."),
    ("CAP-OS-002", .info, nil),
    ("CAP-POL-001", .info, nil),
    ("CAP-POL-002", .info, nil),
    ("CAP-POL-003", .info, nil),
    ("CAP-POL-004", .info, nil),
    ("CAP-VAL-001", .info, nil),
    ("CAP-DAT-001", .info, nil),
    ("CAP-LIM-001", .warning, "A copy was too large to save (over {limit}). It is still on your clipboard."),
    ("CAP-LIM-002", .info, nil),
    ("CAP-LIM-003", .warning, "A copy of {n} files was trimmed to the first 500."),
    ("CAP-IO-001", .error, "Flotsam couldn't save a copy. The disk may be full or its data folder unreadable."),
    ("SSP-PRM-001", .warning, "Flotsam can't read your screenshot folder. Allow access in System Settings › Privacy & Security › Files and Folders."),
    ("SSP-IO-001", .warning, "Your screenshot folder isn't available, so Flotsam is watching the Desktop instead."),
    ("SSP-IO-002", .info, nil),
    ("SSP-IO-003", .warning, "Your chosen screenshot folder is missing. Screenshot pickup is paused."),
    ("SSP-VAL-001", .info, nil),
    ("SSP-LIM-001", .warning, "A screenshot was too large to import (over {limit})."),
    ("SSP-OS-001", .warning, "Live screenshot watching isn't working. Flotsam is checking every 5 seconds instead."),
    ("LIB-OS-001", .error, "Couldn't paste into that app. The item is on your clipboard; press ⌘V."),
    ("LIB-IO-001", .error, "This item's data is missing, so it was removed."),
    ("LIB-DAT-001", .warning, "The original file or folder has moved or been deleted."),
    ("LIB-OS-002", .warning, "Not copied. Confirm it's you to copy a secure item."),
    ("LIB-DAT-002", .warning, "This secure item can't be unlocked on this Mac."),
    ("ORG-VAL-001", .error, "Tag names must be 1 to 32 characters and unique."),
    ("ORG-VAL-002", .error, "Notes can be up to 2,000 characters."),
    ("ORG-VAL-003", .error, "Only text items can be edited, and they can't be empty."),
    ("ORG-LIM-001", .error, "An item can have up to 10 tags."),
    ("ORG-LIM-002", .error, "You can have up to 100 tags."),
    ("ORG-LIM-003", .error, "That text is over the {limit} limit. Shorten it and try again."),
    ("TRG-VAL-001", .error, "Triggers start with a symbol (like ;), have 2 to 24 characters and contain no spaces."),
    ("TRG-VAL-002", .error, "That trigger is already used by another item."),
    ("TRG-VAL-003", .error, "Shortcuts need ⌘ or ⌃ plus a key, and can't be a reserved system shortcut."),
    ("TRG-VAL-004", .error, "That shortcut is already used in Flotsam."),
    ("TRG-VAL-005", .warning, "An unknown variable was left as plain text."),
    ("TRG-VAL-006", .error, "Secure items can't have a trigger or a shortcut."),
    ("TRG-OS-001", .error, "macOS wouldn't let Flotsam use that shortcut. Try a different one."),
    ("TRG-OS-002", .error, "Couldn't expand that trigger. Your typed text was left as it was."),
    ("TRG-OS-003", .warning, "Typed triggers were paused by macOS and have been restarted."),
    ("TRG-POL-001", .info, nil),
    ("TRG-POL-002", .info, nil),
    ("SHF-OS-001", .error, "Couldn't drag that item out. Try again or paste it from the Library."),
    ("SHF-IO-001", .warning, "A dropped file couldn't be read and was skipped."),
    ("SHF-LIM-001", .warning, "A dropped item was too large to save (over {limit})."),
    ("SHF-VAL-001", .warning, "Flotsam can't store that kind of content."),
    ("STO-DB-001", .error, "Flotsam couldn't save your history. Free up disk space and try again."),
    ("STO-DB-002", .error, "Your history database was damaged. A fresh one was created and the old file was kept in the data folder."),
    ("STO-DB-003", .fatal, "Flotsam can't open its history after an update. Your data is untouched; reinstall the previous version or reveal the data folder."),
    ("STO-DB-004", .error, "Couldn't read your history. Try again."),
    ("STO-IO-001", .error, "Flotsam couldn't write to its data folder. Check free disk space."),
    ("STO-IO-002", .fatal, "Flotsam can't create its data folder, so it can't run."),
    ("STO-IO-003", .info, nil),
    ("STO-LIM-001", .warning, "Pinned and shortcut items alone exceed your image budget."),
    ("STO-LIM-002", .warning, "Disk space is low, so Flotsam isn't saving images."),
    ("STO-POL-001", .info, nil),
    ("SET-PRM-001", .warning, "Accessibility is off, so Flotsam can't paste for you. The item is on your clipboard; press ⌘V."),
    ("SET-PRM-002", .warning, "Input Monitoring is off, so typed triggers are paused. Turn it on in System Settings › Privacy & Security."),
    ("SET-OS-001", .error, "Couldn't change Launch at Login. Check System Settings › General › Login Items."),
    ("SET-VAL-001", .error, "That folder can't be used for screenshots. Choose a folder you can read."),
    ("SET-VAL-002", .error, "That isn't an app Flotsam can add. Choose an application."),
    ("SET-DAT-001", .warning, "A setting had an invalid value and was reset to its default."),
]

private func catalogueText(_ row: Row) -> String? {
    row.message?.replacingOccurrences(of: "{limit}", with: "%@").replacingOccurrences(of: "{n}", with: "%lld")
}

private func rows(prefix: String) -> [Row] { section7.filter { $0.code.hasPrefix(prefix + "-") } }

/// Shared per-module check for OC-0057...OC-0065.
private func verifyModule(_ prefix: String, expectedCount: Int) throws {
    let catalogue = try Repo.catalogue()
    let expectedRows = rows(prefix: prefix)
    #expect(expectedRows.count == expectedCount, "literal table has \(expectedRows.count) \(prefix) rows")
    let live = ErrorCode.allCases.filter { $0.rawValue.hasPrefix(prefix + "-") }.map(\.rawValue)
    #expect(Set(live) == Set(expectedRows.map(\.code)), "\(prefix): enum codes differ from section 7")
    #expect(live.count == expectedCount, "\(prefix): enum has \(live.count) codes")
    for row in expectedRows {
        guard let code = ErrorCode(rawValue: row.code) else {
            Issue.record("\(row.code) is not an ErrorCode")
            continue
        }
        #expect(code.severity == row.severity, "\(row.code) severity")
        #expect(catalogue[code.catalogueKey] == catalogueText(row), "\(row.code) catalogue text")
        #expect(FlotsamStrings.text(forKey: code.catalogueKey) == catalogueText(row), "\(row.code) runtime text")
    }
}

@Suite struct ErrorTaxonomyTests {
    // MARK: OC-0005

    /// OC-0005. given the shipped enum, when raw values are matched against the format regex and the section 7
    /// table, then 0 malformed, 0 duplicate, set equals the 63 live codes, retired ORG-VAL-004/005 are not members.
    @Test("OC-0005 code set equals the 63 live codes of section 7")
    func codeSetEqualsSection7() {
        let raws = ErrorCode.allCases.map(\.rawValue)
        #expect(raws.count == 63)
        #expect(Set(raws).count == 63, "duplicate raw value")
        #expect(Set(raws) == Set(section7.map(\.code)))
        let pattern = "^(SYS|CAP|SSP|LIB|ORG|TRG|SHF|STO|SET)-(PRM|IO|DB|VAL|LIM|OS|POL|DAT|INT)-[0-9]{3}$"
        let malformed = raws.filter { $0.range(of: pattern, options: .regularExpression) == nil }
        #expect(malformed.isEmpty, "\(malformed)")
        #expect(ErrorCode(rawValue: "ORG-VAL-004") == nil)
        #expect(ErrorCode(rawValue: "ORG-VAL-005") == nil)
    }

    /// OC-0005 negative. given malformed code strings, when parsed, then every one is rejected; a good one parses.
    @Test("OC-0005 malformed code shapes are rejected by the parser")
    func malformedCodesRejected() {
        for bad in ["CPA-IO-001", "CAP-XX-001", "CAP-IO-01", "CAP-IO-0001", "CAP-IO-000", "cap-io-001", "CAP-IO", "CAP-IO-001-X", "", "CAP-IO-00a"] {
            #expect(ErrorCodeParts.parse(bad) == nil, "\(bad) should not parse")
        }
        let parsed = ErrorCodeParts.parse("TRG-VAL-005")
        #expect(parsed?.module == .trg)
        #expect(parsed?.category == .val)
        #expect(parsed?.number == 5)
        #expect(ErrorCodeParts.parse("CAP-IO-999")?.number == 999)
    }

    // MARK: OC-0006, OC-0007

    /// OC-0006. given the enum, when every POL code is read, then all 7 are Info and none has a catalogue message.
    @Test("OC-0006 all seven POL codes are Info with no message")
    func polCodesAreInfoWithoutMessage() throws {
        let polRaws = ["CAP-POL-001", "CAP-POL-002", "CAP-POL-003", "CAP-POL-004", "TRG-POL-001", "TRG-POL-002", "STO-POL-001"]
        let catalogue = try Repo.catalogue()
        #expect(ErrorCode.allCases.filter { $0.parts?.category == .pol }.count == 7, "a POL code is missing or extra")
        for raw in polRaws {
            let code = try #require(ErrorCode(rawValue: raw), "\(raw) missing")
            #expect(code.severity == .info, "\(raw)")
            #expect(catalogue["error.\(raw)"] == nil, "\(raw) has a message")
        }
    }

    /// OC-0007. given the enum, when grouped by severity, then exactly 2 Fatal (STO-IO-002, STO-DB-003) and
    /// 22 Warning, 25 Error, 14 Info out of 63.
    @Test("OC-0007 severity counts are 2 fatal, 22 warning, 25 error, 14 info")
    func severityCounts() {
        func raws(_ severity: ErrorSeverity) -> Set<String> {
            Set(ErrorCode.allCases.filter { $0.severity == severity }.map(\.rawValue))
        }
        #expect(raws(.fatal) == ["STO-IO-002", "STO-DB-003"])
        #expect(raws(.warning).count == 22)
        #expect(raws(.error).count == 25)
        #expect(raws(.info).count == 14)
        #expect(ErrorCode.allCases.count == 63)
    }

    // MARK: OC-0057 ... OC-0065

    @Test("OC-0057 SYS codes: 1, severity and verbatim text") func sys() throws { try verifyModule("SYS", expectedCount: 1) }
    @Test("OC-0058 CAP codes: 13, severity and verbatim text") func cap() throws { try verifyModule("CAP", expectedCount: 13) }
    @Test("OC-0059 SSP codes: 7, severity and verbatim text") func ssp() throws { try verifyModule("SSP", expectedCount: 7) }
    @Test("OC-0060 LIB codes: 5, severity and verbatim text") func lib() throws { try verifyModule("LIB", expectedCount: 5) }
    @Test("OC-0061 ORG codes: 6 live, severity and verbatim text") func org() throws { try verifyModule("ORG", expectedCount: 6) }
    @Test("OC-0062 TRG codes: 11, severity and verbatim text") func trg() throws { try verifyModule("TRG", expectedCount: 11) }
    @Test("OC-0063 SHF codes: 4, severity and verbatim text") func shf() throws { try verifyModule("SHF", expectedCount: 4) }
    @Test("OC-0064 STO codes: 10, severity and verbatim text") func sto() throws { try verifyModule("STO", expectedCount: 10) }
    @Test("OC-0065 SET codes: 6, severity and verbatim text") func set() throws { try verifyModule("SET", expectedCount: 6) }

    /// OC-0061 retired. given ORG-VAL-004/005 retired, when the catalogue is read, then neither key exists and
    /// neither retired text appears anywhere in the catalogue.
    @Test("OC-0061 retired ORG-VAL-004/005 have no key and no text in the catalogue")
    func retiredOrgCodesAbsent() throws {
        let catalogue = try Repo.catalogue()
        #expect(catalogue["error.ORG-VAL-004"] == nil)
        #expect(catalogue["error.ORG-VAL-005"] == nil)
        let values = Array(catalogue.values)
        #expect(!values.contains("Select at least two files, folders or images to group."))
        #expect(!values.contains("Names must be 1 to 80 characters."))
    }

    // MARK: OC-0016, OC-0020, OC-0053

    /// OC-0016 / OC-0020 / OC-0053. given the shipped catalogue, when its keys are listed, then source language is
    /// en and the error.* keys are exactly the 49 Warning/Error/Fatal codes: none for the 14 Info or 2 retired.
    @Test("OC-0016 OC-0020 OC-0053 catalogue error keys are exactly the 49 non-Info codes")
    func catalogueKeysMatchNonInfoCodes() throws {
        #expect(try Repo.catalogueSourceLanguage() == "en")
        let catalogue = try Repo.catalogue()
        let expectedKeys = Set(section7.filter { $0.message != nil }.map { "error.\($0.code)" })
        #expect(expectedKeys.count == 49)
        #expect(Set(catalogue.keys.filter { $0.hasPrefix("error.") }) == expectedKeys)
        let infoKeys = section7.filter { $0.message == nil }.map { "error.\($0.code)" }
        #expect(infoKeys.count == 14)
        for key in infoKeys { #expect(catalogue[key] == nil, "\(key) must have no message") }
        for retired in ["error.ORG-VAL-004", "error.ORG-VAL-005"] { #expect(catalogue[retired] == nil) }
        for code in ErrorCode.allCases where code.severity != .info {
            #expect(catalogue[code.catalogueKey] != nil, "\(code.rawValue) has no key")
        }
    }

    // MARK: OC-0018

    private func nonInfoMessages() throws -> [(code: String, text: String)] {
        let catalogue = try Repo.catalogue()
        return catalogue.filter { $0.key.hasPrefix("error.") }.map { (String($0.key.dropFirst(6)), $0.value) }.sorted { $0.code < $1.code }
    }

    /// OC-0018 length. given every message, then each is at most 140 characters (140 passes, 141 would not).
    @Test("OC-0018 every message is at most 140 characters")
    func messageLength() throws {
        let messages = try nonInfoMessages()
        #expect(messages.count == 49)
        for (code, text) in messages { #expect(text.count <= 140, "\(code) is \(text.count) characters") }
    }

    /// OC-0018 sentences. given every message, then each has 1 or 2 sentences. FRD-000 section 7 gives STO-DB-003 three
    /// (OC-0064 requires that text verbatim), so a red result here names a contract conflict, not a test error.
    @Test("OC-0018 every message has 1 or 2 sentences")
    func messageSentenceCount() throws {
        for (code, text) in try nonInfoMessages() {
            var sentences = 0
            let characters = Array(text)
            for (index, character) in characters.enumerated() where ".!?".contains(character) {
                if index == characters.count - 1 || characters[index + 1] == " " { sentences += 1 }
            }
            #expect((1...2).contains(sentences), "\(code) has \(sentences) sentences: \(text)")
        }
    }

    /// OC-0018 no code in text. given every message, then none contains a code-shaped substring.
    @Test("OC-0018 no message contains an error-code-shaped substring")
    func messagesHideCodes() throws {
        for (code, text) in try nonInfoMessages() {
            #expect(text.range(of: "[A-Z]{3}-[A-Z]{2,3}-[0-9]{3}", options: .regularExpression) == nil, "\(code)")
        }
    }

    /// OC-0018 placeholders. given every message, then it contains only `%@` or `%lld` placeholders, and exactly the
    /// five messages the table marks `{limit}` / `{n}` have one.
    @Test("OC-0018 placeholders are only %@ and %lld, on exactly the five expected codes")
    func messagePlaceholders() throws {
        var withPlaceholder: Set<String> = []
        for (code, text) in try nonInfoMessages() {
            let stripped = text.replacingOccurrences(of: "%@", with: "").replacingOccurrences(of: "%lld", with: "")
            #expect(!stripped.contains("%"), "\(code) has an unsupported placeholder")
            if stripped != text { withPlaceholder.insert(code) }
        }
        #expect(withPlaceholder == ["CAP-LIM-001", "CAP-LIM-003", "SSP-LIM-001", "ORG-LIM-003", "SHF-LIM-001"])
    }

    // MARK: OC-0050, OC-0051

    /// OC-0050. given a code whose key is absent or whose arguments do not match, when its message is built, then the
    /// SYS-INT-001 text is returned (never a corrupted string). The matching call is the positive control.
    @Test("OC-0050 missing key or placeholder mismatch falls back to the SYS-INT-001 text")
    func messageFallsBackToInternalError() {
        let fallback = "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About."
        #expect(FlotsamStrings.message(for: .capPol001) == fallback, "Info code has no key")
        #expect(FlotsamStrings.message(for: .capLim001) == fallback, "placeholder with no argument")
        #expect(FlotsamStrings.message(for: .sysInt001, arguments: [.count(1)]) == fallback, "argument with no placeholder")
        #expect(FlotsamStrings.message(for: .capLim003, arguments: [.count(1), .count(2)]) == fallback, "too many arguments")
        #expect(FlotsamStrings.message(for: .capLim003, arguments: [.count(501)]) == "A copy of 501 files was trimmed to the first 500.")
    }

    /// OC-0051. given the shipped catalogue, when SYS-INT-001 is read, then severity Error, exact text, 140 or less.
    @Test("OC-0051 SYS-INT-001 is Error with the exact text")
    func sysInt001() {
        #expect(ErrorCode.sysInt001.severity == .error)
        let text = FlotsamStrings.text(forKey: "error.SYS-INT-001")
        #expect(text == "Something unexpected went wrong. Try again; if it keeps happening, copy diagnostics from Settings › About.")
        #expect((text?.count ?? 999) <= 140)
    }

    // MARK: OC-0019

    /// OC-0019. given an over-limit text of 10 MiB, when CAP-LIM-001 raises, then the limit reads "10 MB". 10 MiB is
    /// 10,485,760 bytes; `ByteCountFormatter(.file)` is decimal and yields "10.5 MB", so red here means the contract
    /// and the formatter disagree (limit constant or formatter style).
    @Test("OC-0019 CAP-LIM-001 shows a 10 MiB limit as '10 MB'")
    func capLim001ShowsTenMB() {
        let error = FlotsamError(.capLim001, "test", context: [.limitBytes: .bytes(10_485_760)])
        #expect(FlotsamStrings.message(for: error) == "A copy was too large to save (over 10 MB). It is still on your clipboard.")
    }

    /// OC-0019 count. given a 501-file copy, when CAP-LIM-003 raises, then the message shows 501.
    @Test("OC-0019 CAP-LIM-003 shows the count 501")
    func capLim003ShowsCount() {
        let error = FlotsamError(.capLim003, "test", context: [.count: .int(501)])
        #expect(FlotsamStrings.message(for: error) == "A copy of 501 files was trimmed to the first 500.")
    }

    /// OC-0019 formatter control. given a round binary size (25 MiB), then it formats without a fraction (guards the
    /// formatter style itself, so a red OC-0019 test above is attributable).
    @Test("OC-0019 formatter renders 26,214,400 bytes (25 MiB) as '25 MB'")
    func formatterRoundSize() {
        #expect(MessageArgument.formatBytes(26_214_400) == "25 MB")
    }
}
