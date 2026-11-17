import Foundation

/// Plain text out of RTF or HTML (FR-001-10: richText's plain-text projection feeds search and the content key).
///
/// Foundation-only on purpose: `NSAttributedString` document import lives in AppKit and spins up WebKit for HTML,
/// neither of which belongs in the pure Payload layer or on a background actor. These are small tolerant strippers,
/// not parsers; malformed input yields whatever text was recoverable, never an error.
enum MarkupText {
    // MARK: RTF

    private static let skippedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "expandedcolortbl", "listtable",
        "listoverridetable", "generator", "themedata", "colorschememapping", "datastore", "latentstyles", "fldinst",
    ]

    static func plainText(fromRTF data: Data) -> String {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        var skipDepths: [Int] = []          // group depths at which a skipped destination started
        var depth = 0
        var unicodeSkip = 1                 // \ucN: fallback bytes after a \uN escape
        var pendingFallbackSkip = 0
        var index = 0

        func emitting() -> Bool { skipDepths.isEmpty }
        func append(scalar: UInt32) {
            guard emitting(), let value = Unicode.Scalar(scalar) else { return }
            out.append(contentsOf: Array(String(Character(value)).utf8))
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                depth += 1; index += 1
            case UInt8(ascii: "}"):
                if skipDepths.last == depth { skipDepths.removeLast() }
                depth = max(0, depth - 1); index += 1
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { break }
                let next = bytes[index]
                if isLetter(next) {
                    var word = ""
                    while index < bytes.count, isLetter(bytes[index]) { word.append(Character(UnicodeScalar(bytes[index]))); index += 1 }
                    var number = ""
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { number = "-"; index += 1 }
                    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                        number.append(Character(UnicodeScalar(bytes[index]))); index += 1
                    }
                    if index < bytes.count, bytes[index] == UInt8(ascii: " ") { index += 1 }   // delimiter space
                    if skipDepths.isEmpty, skippedDestinations.contains(word) { skipDepths.append(depth) }
                    switch word {
                    case "par", "line", "sect", "page": if emitting() { out.append(10) }
                    case "tab": if emitting() { out.append(9) }
                    case "uc": unicodeSkip = Int(number) ?? 1
                    case "u":
                        if let raw = Int(number) {
                            append(scalar: UInt32(truncatingIfNeeded: raw < 0 ? raw + 65536 : raw))
                            pendingFallbackSkip = unicodeSkip
                        }
                    default: break
                    }
                } else if next == UInt8(ascii: "*") {
                    // Optional destination: ignore the whole group unless it is a known text-bearing one.
                    if skipDepths.isEmpty { skipDepths.append(depth) }
                    index += 1
                } else if next == UInt8(ascii: "'") {
                    if index + 2 < bytes.count, let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                        if pendingFallbackSkip > 0 { pendingFallbackSkip -= 1 } else { append(scalar: windows1252(value)) }
                    }
                    index += 3
                } else {
                    if emitting(), next == UInt8(ascii: "\\") || next == UInt8(ascii: "{") || next == UInt8(ascii: "}") { out.append(next) }
                    index += 1
                }
            case 10, 13:
                index += 1                      // raw line breaks in RTF source are not content
            default:
                if pendingFallbackSkip > 0 { pendingFallbackSkip -= 1 } else if emitting() { out.append(byte) }
                index += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    /// Windows-1252 high range for the few characters that differ from Latin-1 (RTF `\'hh` is ANSI by default).
    private static func windows1252(_ value: UInt8) -> UInt32 {
        let specials: [UInt8: UInt32] = [
            0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
            0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
            0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
            0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
        ]
        return specials[value] ?? UInt32(value)
    }

    // MARK: HTML

    static func plainText(fromHTML data: Data) -> String {
        var html = String(decoding: data, as: UTF8.self)
        html = html.replacing(/(?is)<!--.*?-->/, with: "")
        html = html.replacing(/(?is)<(script|style|head)\b.*?<\/\1\s*>/, with: "")
        html = html.replacing(/(?i)<br\s*\/?>|<\/(?:p|div|li|tr|h[1-6])\s*>/, with: "\n")
        html = html.replacing(/<[^>]*>/, with: "")
        return decodeEntities(html)
    }

    private static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]

    private static func decodeEntities(_ text: String) -> String {
        text.replacing(/&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);/) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let body = name.dropFirst()
                let value = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let value, let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
                return String(match.output.0)
            }
            return namedEntities[name] ?? String(match.output.0)
        }
    }
}
