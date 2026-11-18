import Foundation

/// A colour item's value as three 0...255 channels. One parse for every surface that draws or lists a colour (the
/// Library preview's swatch, hex and rgb values; the Shelf card's swatch), so a notation is accepted in one place.
///
/// Accepted: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA` and `rgb(...)` / `rgba(...)` with numbers or percentages (alpha is
/// ignored). `hsl()` and anything else is nil: such an item shows its text and no swatch.
///
/// This type is also the one home of the colour-notation rule: `isNotation(_:)` says whether text is a colour at all
/// (the same grammar plus `hsl()` / `hsla()`), and the typed-text detector classifies by it (FR-003-14). Digits are
/// ASCII only, everywhere.
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

    /// True when the whole trimmed text is a colour notation: hex (3, 4, 6 or 8 ASCII hex digits) or `rgb()` / `rgba()` /
    /// `hsl()` / `hsla()` with three or four ASCII-digit numbers or percentages. Having a notation does not mean having
    /// a swatch: `hsl()` is a colour with no `ColorChannels`.
    public static func isNotation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return parseHex(String(trimmed.dropFirst())) != nil }
        return parseFunctionCall(trimmed) != nil
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

    /// `rgb()` / `rgba()` only: the swatch notations.
    private static func parseFunction(_ text: String) -> ColorChannels? {
        guard let call = parseFunctionCall(text), call.name == "rgb" || call.name == "rgba" else { return nil }
        var channels: [Int] = []
        for argument in call.arguments.prefix(3) {
            channels.append(argument.isPercent ? clampedInt(argument.value * 2.55) : clampedInt(argument.value))
        }
        return ColorChannels(red: channels[0], green: channels[1], blue: channels[2])
    }

    private struct Argument {
        let value: Double
        let isPercent: Bool
    }

    /// The one function-notation grammar: `rgb|rgba|hsl|hsla ( a b c [d] )`, name case-insensitive, three or four
    /// arguments. Comma and slash delimit slots, whitespace separates within a slot; an empty slot ("1,,2,3",
    /// "(,1,2,3)") is garbage. Every argument, alpha included, must be a number or percentage.
    private static func parseFunctionCall(_ text: String) -> (name: String, arguments: [Argument])? {
        let lowered = text.lowercased()
        guard let open = lowered.firstIndex(of: "("), lowered.hasSuffix(")") else { return nil }
        let name = String(lowered[lowered.startIndex..<open])
        guard ["rgb", "rgba", "hsl", "hsla"].contains(name) else { return nil }
        let inside = lowered[lowered.index(after: open)..<lowered.index(before: lowered.endIndex)]
        let slots = inside.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "/" })
        var arguments: [Argument] = []
        for slot in slots {
            let tokens = slot.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { return nil }
            for token in tokens {
                guard let value = parseNumber(token) else { return nil }
                arguments.append(Argument(value: value, isPercent: token.hasSuffix("%")))
            }
        }
        guard arguments.count == 3 || arguments.count == 4 else { return nil }
        return (name, arguments)
    }

    /// A plain decimal number with an optional trailing "%" (sign, digits, one point; no exponent, "nan", "inf" or hex).
    /// The pattern fixes the shape: `Double(_:)` alone would accept exponents, "nan", "inf" and hex floats. Digits are
    /// ASCII because `Double(_:)` rejects any other digit; the `[0-9]` class is not what excludes them. A number too
    /// large for `Double` (309 or more digits) is infinite and so rejected: a non-finite number is not a colour.
    /// Returns the numeric part, always finite; nil for anything else.
    private static func parseNumber(_ token: Substring) -> Double? {
        let body = token.hasSuffix("%") ? token.dropLast() : token
        guard body.wholeMatch(of: /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)/) != nil,
              let value = Double(body), value.isFinite else { return nil }
        return value
    }

    /// Rounds to the nearest integer after clamping to 0...255, so a huge value never reaches `Int(_:)` (which traps).
    private static func clampedInt(_ value: Double) -> Int {
        Int(min(max(value, 0), 255).rounded())
    }
}
