import Foundation
import Testing
@testable import FlotsamBase

// TASK-413 blind QA (Worf), branch worf-413. FRD-003 FR-003-14: a colour is swatched, with hex and rgb values, "for hex
// and rgb() notations; any other notation shows its text and no swatch". OC-3058 (#1A2B3C -> 26, 43, 60).
// Expected side is literals only. Each test names the change that turns it red.

@Suite struct Worf413ColorChannelsTests {
    private func parse(_ text: String?) -> [Int]? {
        ColorChannels(text: text).map { [$0.red, $0.green, $0.blue] }
    }

    // OC-3058. Red if the hex parse reads channels in the wrong order or drops the leading '#'.
    @Test("OC-3058 #1A2B3C reads 26, 43, 60 and renders back as #1A2B3C / '26, 43, 60'")
    func w413_longHex() throws {
        // given/when: the contract colour
        let color = try #require(ColorChannels(text: "#1A2B3C"))
        // then
        let triple: [Int] = [color.red, color.green, color.blue]
        #expect(triple == [26, 43, 60])
        #expect(color.hex == "#1A2B3C")
        #expect(color.channels == "26, 43, 60")
    }

    // Red if short hex is not doubled per digit (e.g. "#1A2" read as 0x1, 0xA, 0x2 -> 1, 10, 2), or is rejected.
    @Test("W413-C1 #RGB doubles each digit; #RGBA ignores alpha")
    func w413_shortHex() {
        #expect(parse("#1A2") == [17, 170, 34])
        #expect(parse("#fff") == [255, 255, 255])
        #expect(parse("#000") == [0, 0, 0])
        #expect(parse("#1A2F") == [17, 170, 34])
        #expect(parse("#0000") == [0, 0, 0])
    }

    // Red if the 8-digit form is rejected or the alpha pair is taken as a channel.
    @Test("W413-C2 #RRGGBBAA ignores alpha")
    func w413_hexAlpha() {
        #expect(parse("#1A2B3C80") == [26, 43, 60])
        #expect(parse("#1A2B3CFF") == [26, 43, 60])
        #expect(parse("#FF000000") == [255, 0, 0])
    }

    // Red if the length gate admits 1, 2, 5, 7, 9 digits, or an empty '#'. Boundary: 3,4,6,8 ok; neighbours nil.
    @Test("W413-C3 hex digit counts other than 3, 4, 6, 8 are nil")
    func w413_hexLengths() {
        for text in ["#", "#1", "#12", "#12345", "#1234567", "#123456789"] {
            #expect(parse(text) == nil, "\(text)")
        }
    }

    // Red if non-hex characters are tolerated (e.g. parsed with a lenient scanner).
    @Test("W413-C4 non-hex digits and a missing '#' are nil")
    func w413_hexGarbage() {
        for text in ["#GGGGGG", "#12345G", "#1A2B3C ZZ", "1A2B3C", "##1A2B3C", "#1A 2B3C", "#-1A2B3", "#+1A2B3"] {
            #expect(parse(text) == nil, "\(text)")
        }
    }

    // Red if hex digits are matched with Character.isHexDigit alone: it also admits full-width digits, and a dropped pair
    // then shifts the channels (DEFECT D1, see report) - "#Ｆ0112233" would read as 17, 34, 51.
    @Test("W413-C5 full-width (non-ASCII) hex digits are nil, never a shifted colour")
    func w413_unicodeHex() {
        #expect(parse("#Ｆ0112233") == nil)
        #expect(parse("#ＦＦ0000") == nil)
    }

    // Red if trimming or case folding is removed.
    @Test("W413-C6 surrounding whitespace and hex case are ignored")
    func w413_whitespaceCase() {
        #expect(parse("  #1a2b3c\n") == [26, 43, 60])
        #expect(parse("\t#1A2b3C ") == [26, 43, 60])
        #expect(parse("  RGB(1, 2, 3)  ") == [1, 2, 3])
        #expect(parse("Rgb(1,2,3)") == [1, 2, 3])
    }

    // Red if nil / empty / blank is not guarded (B6 empty case).
    @Test("W413-C7 nil, empty and blank text are nil")
    func w413_empty() {
        #expect(parse(nil) == nil)
        #expect(parse("") == nil)
        #expect(parse("   \n") == nil)
    }

    // Red if rgb() is read without splitting on commas, or channels are reordered.
    @Test("W413-C8 rgb() with numbers: comma, space and spaced-comma separators")
    func w413_rgbNumbers() {
        #expect(parse("rgb(26,43,60)") == [26, 43, 60])
        #expect(parse("rgb(26, 43, 60)") == [26, 43, 60])
        #expect(parse("rgb(26 43 60)") == [26, 43, 60])
        #expect(parse("rgb(0, 0, 0)") == [0, 0, 0])
        #expect(parse("rgb(255, 255, 255)") == [255, 255, 255])
    }

    // Red if rgba() is rejected, or the alpha is taken as a channel, or '/' syntax breaks.
    @Test("W413-C9 rgba() and the slash form ignore alpha")
    func w413_rgba() {
        #expect(parse("rgba(26, 43, 60, 0.5)") == [26, 43, 60])
        #expect(parse("rgba(26,43,60,1)") == [26, 43, 60])
        #expect(parse("rgb(26 43 60 / 50%)") == [26, 43, 60])
        #expect(parse("rgb(26, 43, 60, 0.5)") == [26, 43, 60])
        #expect(parse("rgba(26, 43, 60)") == [26, 43, 60])
    }

    // Red if percentages are read as raw numbers (100% -> 100) or the scale is not 2.55.
    @Test("W413-C10 rgb() with percentages scales 0-100% to 0-255")
    func w413_rgbPercent() {
        #expect(parse("rgb(100%, 0%, 0%)") == [255, 0, 0])
        #expect(parse("rgb(0%, 100%, 0%)") == [0, 255, 0])
        #expect(parse("rgb(20%, 40%, 60%)") == [51, 102, 153])
        #expect(parse("rgba(100%, 100%, 100%, 0.5)") == [255, 255, 255])
    }

    // Red if values are truncated instead of rounded, or fractions are rejected.
    @Test("W413-C11 fractional channel numbers round to nearest")
    func w413_rgbFractions() {
        #expect(parse("rgb(25.6, 43.4, 60)") == [26, 43, 60])
    }

    // The clamp is documented on ColorChannels.init(red:green:blue:). Red if the clamp is removed (init would carry 300).
    @Test("W413-C12 out-of-range channels clamp to 0...255 (documented init behaviour)")
    func w413_clamp() {
        #expect(parse("rgb(300, -5, 256)") == [255, 0, 255])
        #expect(parse("rgb(150%, -10%, 100%)") == [255, 0, 255])
        let direct = ColorChannels(red: 999, green: -1, blue: 255)
        let triple: [Int] = [direct.red, direct.green, direct.blue]
        #expect(triple == [255, 0, 255])
    }

    // Red if hsl()/hsla()/named/other notations get a swatch (FR-003-14: "any other notation shows its text and no swatch").
    @Test("W413-C13 hsl(), hsla(), named colours and other notations are nil")
    func w413_otherNotations() {
        for text in ["hsl(210, 50%, 40%)", "hsla(210, 50%, 40%, 0.5)", "red", "blue", "color(srgb 1 0 0)", "oklch(0.5 0.2 30)", "hwb(0 0% 0%)"] {
            #expect(parse(text) == nil, "\(text)")
        }
    }

    // Red if the function parser is lenient about arity, name, brackets or number syntax.
    @Test("W413-C14 malformed rgb(): wrong arity, no brackets, bad names, non-numbers are nil")
    func w413_rgbMalformed() {
        let bad = [
            "rgb()", "rgb(1)", "rgb(1, 2)", "rgb(1, 2, 3, 4, 5)", "rgb(1, 2, 3", "rgb 1, 2, 3)", "rgb(a, b, c)",
            "rgb(1, 2, x)", "rgbx(1, 2, 3)", "rgb (1, 2, 3)", "rgb", "rgb(1%%, 2, 3)", "rgb(%, 2, 3)", "(1, 2, 3)", "1, 2, 3",
            "rgb(1, 2, 3) extra", "prgb(1, 2, 3)",
        ]
        for text in bad { #expect(parse(text) == nil, "\(text)") }
    }

    // Red if an empty slot ("rgb(1,,2,3)") is silently swallowed as a valid 3-channel colour.
    @Test("W413-C15 a doubled comma is garbage, not a colour")
    func w413_doubledComma() {
        #expect(parse("rgb(1,,2,3)") == nil)
        #expect(parse("rgb(,1,2,3)") == nil)
    }

    // Red if the 4th (alpha) slot is accepted without being validated.
    @Test("W413-C16 a non-numeric alpha is garbage")
    func w413_badAlpha() {
        #expect(parse("rgba(1, 2, 3, banana)") == nil)
    }

    // Red (CRASH) if a non-finite or huge number reaches Int(...) unguarded: Double("nan"), Double("inf"), Double("1e30")
    // are all valid Doubles and Int(_:) traps on them (DEFECT D2, see report). Run in a child process so a trap is a red
    // test, not a dead suite. The digits-only cases below are REACHABLE: TypedTextDetector.isColor classifies
    // "rgb(99999999999999999999, 0, 0)" as a .color item, so copying that text crashes the Library preview and Shelf card.
    @Test("W413-C17 nan / inf / huge numbers in rgb() never crash the parser")
    func w413_nonFinite() async {
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(99999999999999999999, 0, 0)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(99999999999999999999%, 0%, 0%)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(nan, 0, 0)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(inf, 0, 0)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(1e30, 0, 0)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(nan%, 0%, 0%)") }
        await #expect(processExitsWith: .success) { _ = ColorChannels(text: "rgb(1e30%, 0%, 0%)") }
    }
}
