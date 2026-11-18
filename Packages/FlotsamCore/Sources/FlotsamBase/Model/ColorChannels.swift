import Foundation

/// A colour item's value as three 0...255 channels. One parse for every surface that draws or lists a colour (the
/// Library preview's swatch, hex and rgb values; the Shelf card's swatch), so a notation is accepted in one place.
///
/// Accepted: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` and `rgb(...)` / `rgba(...)` with numbers or percentages (alpha is
/// ignored). `hsl()` and anything else is nil: such an item shows its text and no swatch.
public struct ColorChannels: Sendable, Equatable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = min(max(red, 0), 255)
        self.green = min(max(green, 0), 255)
        self.blue = min(max(blue, 0), 255)
    }

    public init?(text: String?) {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("#") {
            guard let parsed = Self.parseHex(String(trimmed.dropFirst())) else { return nil }
            self = parsed
        } else {
            guard let parsed = Self.parseFunction(trimmed) else { return nil }
            self = parsed
        }
    }

    /// "#1A2B3C".
    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// "26, 43, 60".
    public var channels: String { "\(red), \(green), \(blue)" }

    private static func parseHex(_ digits: String) -> ColorChannels? {
        guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        let expanded = digits.count <= 4 ? digits.flatMap { [$0, $0] } : Array(digits)
        let bytes = stride(from: 0, to: expanded.count, by: 2).compactMap { UInt8(String(expanded[$0...$0 + 1]), radix: 16) }
        guard bytes.count >= 3 else { return nil }
        return ColorChannels(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private static func parseFunction(_ text: String) -> ColorChannels? {
        let lowered = text.lowercased()
        guard lowered.hasPrefix("rgb"), let open = lowered.firstIndex(of: "("), lowered.hasSuffix(")") else { return nil }
        let name = lowered[lowered.startIndex..<open]
        guard name == "rgb" || name == "rgba" else { return nil }
        let inside = lowered[lowered.index(after: open)..<lowered.index(before: lowered.endIndex)]
        // Comma and slash delimit slots; whitespace separates within a slot. An empty slot ("1,,2,3", "(,1,2,3)") is garbage.
        let slots = inside.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "/" })
        var parts: [Substring] = []
        for slot in slots {
            let tokens = slot.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { return nil }
            parts.append(contentsOf: tokens)
        }
        guard parts.count == 3 || parts.count == 4 else { return nil }
        // The 4th (alpha) slot is ignored but must still be a number or percentage.
        if parts.count == 4, parseNumber(parts[3]) == nil { return nil }
        var channels: [Int] = []
        for part in parts.prefix(3) {
            guard let value = parseNumber(part) else { return nil }
            channels.append(part.hasSuffix("%") ? Self.clampedInt(value * 2.55) : Self.clampedInt(value))
        }
        return ColorChannels(red: channels[0], green: channels[1], blue: channels[2])
    }

    /// A plain decimal number with an optional trailing "%" (sign, digits, one point; no exponent, "nan", "inf" or hex).
    /// Returns the numeric part, always finite; nil for anything else.
    private static func parseNumber(_ token: Substring) -> Double? {
        let body = token.hasSuffix("%") ? token.dropLast() : token
        guard body.wholeMatch(of: /[+-]?(?:\d+\.?\d*|\.\d+)/) != nil,
              let value = Double(body), value.isFinite else { return nil }
        return value
    }

    /// Rounds to the nearest integer after clamping to 0...255, so a huge value never reaches `Int(_:)` (which traps).
    private static func clampedInt(_ value: Double) -> Int {
        Int(min(max(value, 0), 255).rounded())
    }
}
