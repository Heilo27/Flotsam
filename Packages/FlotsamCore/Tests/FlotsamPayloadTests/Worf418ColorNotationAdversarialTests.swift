import Foundation
import Testing
import FlotsamBase
@testable import FlotsamPayload

/// Worf, TASK-418 (Rule 9: one colour grammar in ColorChannels.isNotation). FR-003-14.
/// Expected values are literals. The equivalence probe's oracle is the PRE-refactor TypedTextDetector.isColor regex,
/// copied verbatim from commit 9d37e08, so a drift in the single grammar is caught against what shipped before.
@Suite struct Worf418ColorNotationAdversarialTests {
    // Verbatim pre-TASK-418 regex (9d37e08). Fed the trimmed text, as TypedTextDetector.detect did.
    private static func oldIsColor(_ text: String) -> Bool {
        if text.wholeMatch(of: /#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})/) != nil { return true }
        return text.wholeMatch(
            of: /(?i)(?:rgba?|hsla?)\(\s*[+-]?(?:\d+\.?\d*|\.\d+)%?(?:\s*[,\/\s]\s*[+-]?(?:\d+\.?\d*|\.\d+)%?){2,3}\s*\)/
        ) != nil
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func generated(count: Int) -> [String] {
        var rng = SplitMix64(state: 0x418)
        let names = ["rgb", "rgba", "hsl", "hsla", "RGB", "RgBa", "HSL", "Hsla", "rgbx", "rg", "hs", "rgbaa", "", "xrgb", "hsv"]
        let opens = ["(", "(", "(", " (", "[", "(\t", "( ", "(\u{00A0}"]
        let closes = [")", ")", ")", " )", "", "]", ")x", "\t)", ")\u{00A0}"]
        let args = ["0", "1", "255", "256", "-1", "+5", "1.5", ".5", "1.", "1..2", "50%", "100%", "%", "1%%", "abc", "1e2",
                    "1.5.5", "", "-", "+", "-.5", "+.5%", "00012", "3.14159", "-0", "0x1", "nan", "inf", "٣", "1٣", "１"]
        let seps = [",", ",", " ", " ", ", ", " , ", "/", " / ", ",,", ", ,", "  ", "\t", "\n", ";", ",/", "/,", " ,", ", /", "\u{00A0}"]
        let pads = ["", "", "", " ", "  ", "\t", "\n", " \n", "\u{00A0}"]
        let hexChars = Array("0123456789abcdefABCDEFgG ")
        let huge = String(repeating: "9", count: 400)
        var out: [String] = []
        out.reserveCapacity(count)
        while out.count < count {
            var s = pads.randomElement(using: &rng)!
            if Int.random(in: 0..<4, using: &rng) == 0 {
                s += Int.random(in: 0..<4, using: &rng) == 0 ? "##" : "#"
                for _ in 0..<Int.random(in: 0...10, using: &rng) { s.append(hexChars.randomElement(using: &rng)!) }
            } else {
                s += names.randomElement(using: &rng)! + opens.randomElement(using: &rng)!
                for index in 0..<Int.random(in: 0...6, using: &rng) {
                    if index > 0 { s += seps.randomElement(using: &rng)! }
                    s += Int.random(in: 0..<40, using: &rng) == 0 ? huge : args.randomElement(using: &rng)!
                }
                s += closes.randomElement(using: &rng)!
            }
            s += pads.randomElement(using: &rng)!
            out.append(s)
        }
        return out
    }

    // OC-418-W1. Red if the single grammar accepts or rejects anything the pre-refactor detector regex did not,
    // other than a non-ASCII digit (none are generated here except the deliberate ٣ / １ cases, filtered below).
    @Test("OC-418-W1 given 10000 generated ASCII inputs, when classified by isNotation, then it agrees with the pre-refactor regex")
    func equivalenceWithOldRegex() {
        let inputs = Self.generated(count: 10_000)
        let nonASCIIDigit = Character("٣"), fullwidth = Character("１")
        // KNOWN DIVERGENCE (see OC-418-W8): a 309+ digit argument overflows Double; old regex = colour, new = not.
        let overflow = String(repeating: "9", count: 309)
        var divergences: [String] = []
        var agreedTrue = 0, agreedFalse = 0
        for input in inputs where !input.contains(nonASCIIDigit) && !input.contains(fullwidth) && !input.contains(overflow) {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let old = Self.oldIsColor(trimmed)
            let new = ColorChannels.isNotation(input)
            if old != new { divergences.append("\(input.debugDescription) old=\(old) new=\(new)") }
            else if old { agreedTrue += 1 } else { agreedFalse += 1 }
        }
        #expect(divergences.isEmpty, "\(divergences.count) divergences, first: \(divergences.prefix(5))")
        // The probe must exercise both outcomes, or an always-false grammar would pass it.
        #expect(agreedTrue > 200)
        #expect(agreedFalse > 1000)
    }

    // OC-418-W2. Red if `[0-9]` is reverted to `\d` (Unicode digits become colour again), or hex stops being ASCII-only.
    @Test("OC-418-W2 given a non-ASCII digit in any slot, when classified, then it is plain text and not a colour")
    func nonASCIIDigitsAreNotColour() {
        let rows = [
            "rgb(٣,2,3)", "rgb(1,٣,3)", "rgb(1,2,٣)", "rgba(1,2,3,٣)", "rgb(1,2,3٣)", "rgb(1.٣,2,3)", "rgb(.٣,2,3)",
            "rgb(٣٣%,2,3)", "rgb(１,2,3)", "rgb(1,2,３)", "hsl(１２０,50%,50%)", "hsla(1,2,3,٣)", "hsl(1,٥٠%,3)",
            "rgb(+٣,2,3)", "rgb(-٣,2,3)", "#１２３", "#١٢٣", "#12٣", "#１２３４５６",
            "#123４", "#123456７８", "#ＡＢＣ４", "#12345678".replacingOccurrences(of: "8", with: "８"),
        ]
        for text in rows {
            #expect(!ColorChannels.isNotation(text), "isNotation \(text)")
            #expect(TypedTextDetector.detect(text) != .color, "detect \(text)")
            #expect(ColorChannels(text: text) == nil, "channels \(text)")
        }
        // Positive control with the same shape, ASCII.
        #expect(ColorChannels.isNotation("rgb(3,2,3)"))
        #expect(ColorChannels.isNotation("hsl(120,50%,50%)"))
    }

    // OC-418-W3. Red if init?(text:) starts returning channels for hsl/hsla.
    @Test("OC-418-W3 given hsl and hsla, when parsed, then they are a colour notation with no swatch; rgb keeps exact channels")
    func hslHasNoSwatchRgbDoes() {
        for text in ["hsl(120,50%,50%)", "hsla(120,50%,50%,0.5)", "HSL(0 0% 0%)", " hsl(1,2,3) ", "Hsla(1 2 3 / 4)"] {
            #expect(ColorChannels.isNotation(text), "notation \(text)")
            #expect(TypedTextDetector.detect(text) == .color, "kind \(text)")
            #expect(ColorChannels(text: text) == nil, "swatch \(text)")
        }
        #expect(ColorChannels(text: "rgb(255,128,0)") == ColorChannels(red: 255, green: 128, blue: 0))
        #expect(ColorChannels(text: "rgba(1 2 3 / 0.5)") == ColorChannels(red: 1, green: 2, blue: 3))
        #expect(ColorChannels(text: "rgb(100%,0%,100%)") == ColorChannels(red: 255, green: 0, blue: 255))
        #expect(ColorChannels(text: "rgb(300,-5,999)") == ColorChannels(red: 255, green: 0, blue: 255))
        #expect(ColorChannels(text: "#1A2B3C") == ColorChannels(red: 0x1A, green: 0x2B, blue: 0x3C))
        #expect(ColorChannels(text: "#abc") == ColorChannels(red: 0xAA, green: 0xBB, blue: 0xCC))
    }

    // OC-418-W4. 0/1/max/max+1 boundaries: hex digit counts and argument counts.
    @Test("OC-418-W4 given hex lengths 0-9 and argument counts 0-5, when classified, then only 3,4,6,8 digits and 3-4 args are colours")
    func lengthBoundaries() {
        let hexExpected = [false, false, false, true, true, false, true, false, true, false]
        for length in 0...9 {
            let text = "#" + String(repeating: "a", count: length)
            #expect(ColorChannels.isNotation(text) == hexExpected[length], "hex length \(length)")
            #expect((TypedTextDetector.detect(text) == .color) == hexExpected[length], "detect hex length \(length)")
        }
        let argExpected = [false, false, false, true, true, false]
        for count in 0...5 {
            let body = Array(repeating: "1", count: count).joined(separator: ",")
            for name in ["rgb", "rgba", "hsl", "hsla"] {
                #expect(ColorChannels.isNotation("\(name)(\(body))") == argExpected[count], "\(name) with \(count) args")
            }
        }
    }

    // OC-418-W5. Whitespace and the empty case: isNotation trims like detect, but never accepts internal line breaks via detect.
    @Test("OC-418-W5 given padding, empty and multi-line text, when classified, then trim applies and empties are not colours")
    func trimAndEmpty() {
        #expect(ColorChannels.isNotation("  \t#fff\n"))
        #expect(ColorChannels.isNotation("\nrgb(1,2,3)  "))
        #expect(!ColorChannels.isNotation(""))
        #expect(!ColorChannels.isNotation("   \n"))
        #expect(!ColorChannels.isNotation("#fff #000"))
        #expect(!ColorChannels.isNotation("rgb(1,2,3) rgb(4,5,6)"))
        #expect(TypedTextDetector.detect("rgb(1,\n2,3)") == nil)
        #expect(TypedTextDetector.detect("#fff\n#000") == nil)
    }

    // OC-418-W6. Red if a swatch-bearing text is ever not a notation (the two entry points disagree: Rule 9 drift).
    @Test("OC-418-W6 given generated inputs, when init?(text:) yields channels, then isNotation is true and the name is rgb or rgba")
    func swatchImpliesNotation() {
        var swatches = 0
        for input in Self.generated(count: 6000) {
            guard ColorChannels(text: input) != nil else { continue }
            swatches += 1
            #expect(ColorChannels.isNotation(input), "swatch without notation: \(input.debugDescription)")
            #expect(!input.lowercased().contains("hsl"), "hsl produced a swatch: \(input.debugDescription)")
        }
        #expect(swatches > 100)
    }

    // OC-418-W8. UNDECLARED BEHAVIOUR CHANGE found by the probe: the old detector regex took any digit run, the shared
    // grammar requires a finite Double. Literal expectations below are the OLD behaviour; red today, by design.
    @Test("OC-418-W8 given an argument of 400 ASCII digits, when classified, then it is still a colour as before the refactor")
    func overflowingNumberKeepsOldClassification() {
        let huge = String(repeating: "9", count: 400)
        #expect(ColorChannels.isNotation("rgb(\(huge),2,3)"))
        #expect(ColorChannels.isNotation("hsl(1,2,\(huge)%)"))
        #expect(TypedTextDetector.detect("rgba(1,2,3,\(huge))") == .color)
    }

    // OC-418-W7. A number too large for Double is not finite; the old regex called it a colour, the shared parser rejects it.
    // Pins whichever answer ships, and fails if the detector and the swatch parser ever disagree about it again.
    @Test("OC-418-W7 given a 400-digit argument, when classified, then isNotation and the swatch parser agree")
    func overflowingNumber() {
        let huge = String(repeating: "9", count: 400)
        let text = "rgb(\(huge),2,3)"
        #expect(ColorChannels.isNotation(text) == (ColorChannels(text: text) != nil))
        let hslText = "hsl(\(huge),2,3)"
        #expect(ColorChannels.isNotation(hslText) == ColorChannels.isNotation(text))
    }
}
