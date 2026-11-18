import FlotsamBase
import Foundation
import Testing
@testable import FlotsamPayload

// TASK-418 characterization. Pins what TypedTextDetector classified as a colour BEFORE the notation rule moved into
// FlotsamBase.ColorChannels (Rule 9), so the move provably changed nothing. FR-003-14: hsl()/hsla() are a colour
// (kind .color) even though they have no swatch. Expected values are the pre-refactor results, as literals.

@Suite struct ColorNotationCharacterizationTests {
    private static let colours: [String] = [
        // hex 3/4/6/8, either case
        "#fff", "#FFF", "#1a2", "#abcd", "#ABCD", "#1A2B3C", "#1a2b3c", "#12345678", "#AbCdEf12",
        // surrounding whitespace is trimmed by detect
        "  #fff  ", "\t#1A2B3C\t", "#fff\n", "rgb(1,2,3) ", "\u{00A0}#fff\u{00A0}",
        // rgb / rgba: commas, spaces, slash, percentages, decimals, signs
        "rgb(0,0,0)", "rgb(255, 255, 255)", "rgb( 1 , 2 , 3 )", "rgb(1 2 3)", "rgb(1  2   3)",
        "rgba(1,2,3,4)", "rgba(1, 2, 3, 0.5)", "rgba(1 2 3 / 0.5)", "rgb(1 2 3 / 50%)", "rgb(1,2,3,.5)",
        "rgb(10%, 20%, 30%)", "rgb(10% 20% 30%)", "rgba(10%,20%,30%,50%)", "rgb(1.5, 2.5, 3.5)",
        "rgb(.5, .5, .5)", "rgb(1., 2., 3.)", "rgb(+1, -2, +3)", "rgb(300, -5, 999)", "rgb(1.5%, 2%, 3%)",
        "RGB(1,2,3)", "Rgb(1, 2, 3)", "RGBA(1,2,3,0.4)", "rgb(1 2,3)", "rgb(1, 2 3)", "rgb(1 / 2 / 3)",
        "rgb(1,2/3,4)", "rgb(1 , 2 , 3 , 4)", "rgba(1,2,3)", "rgb(1,2,3,4)", "rgb(\u{00A0}1,2,3)",
        // hsl / hsla (FR-003-14: classified as colour, no swatch)
        "hsl(0,0%,0%)", "hsl(120, 50%, 50%)", "hsl(120 50% 50%)", "hsla(120, 50%, 50%, 0.5)",
        "hsl(120 50% 50% / 0.5)", "HSL(1,2,3)", "Hsla(1,2,3,4)", "hsl(1.5, 2%, 3%)", "hsl(-10, +20%, .5%)",
        "hsl(360deg, 50%, 50%)".replacingOccurrences(of: "deg", with: ""),
    ]

    private static let notColours: [String] = [
        // empty / whitespace / multi-line
        "", " ", "\n", "#fff\n#000", "rgb(1,2,3)\nrgb(4,5,6)",
        // hex malformed
        "#", "#f", "#ff", "#fffff", "#fffffff", "#123456789", "#ggg", "#12345g", "fff", "123456", "# fff", "#f f f",
        "##fff", "#fff;", "#fff,", "#ａｂｃ", "#١٢٣", "0xfff",
        // function malformed
        "rgb()", "rgb(1,2)", "rgb(1)", "rgb(1,2,3,4,5)", "rgb(1 2 3 4 5)", "rgb(1,,2,3)", "rgb(,1,2,3)", "rgb(1,2,3,)",
        "rgb(1,2,3", "rgb 1,2,3)", "rgb (1,2,3)", "rgb(1,2,3)x", "xrgb(1,2,3)", "rgbx(1,2,3)",
        "rgb(a,b,c)", "rgb(1,2,x)", "rgb(1,2,3,x)", "rgb(1e2,2,3)", "rgb(0x10,2,3)", "rgb(nan,2,3)", "rgb(inf,2,3)",
        "rgb(1,2,3%%)", "rgb(%,2,3)", "rgb(1%%,2,3)", "rgb(--1,2,3)", "rgb(+-1,2,3)", "rgb(1.2.3,2,3)", "rgb(.,2,3)",
        "rgb(1, / 2, 3)", "rgb(1 /, 2, 3)", "rgb(1,/2,3)", "rgb(1 , , 2, 3)", "rgb(1;2;3)", "rgb(1 2 3;)",
        "rgb(1px, 2px, 3px)", "rgb(1,2,3)rgb(1,2,3)", "rgb[1,2,3]", "rgb{1,2,3}",
        "hsl()", "hsl(1,2)", "hsl(1,2,3,4,5)", "hsl(1,,2,3)", "hsl(a,b,c)", "hsl(120deg, 50%, 50%)", "hsl (1,2,3)",
        "hsv(1,2,3)", "hsb(1,2,3)", "cmyk(1,2,3,4)", "lab(1,2,3)", "hwb(1,2,3)", "oklch(1,2,3)", "color(1,2,3)",
        "rgbhsl(1,2,3)", "hslrgb(1,2,3)", "rgbaa(1,2,3)", "hslaa(1,2,3)",
        // DELIBERATE TASK-418 CHANGE (not pinned pre-refactor behaviour): non-ASCII digits were .color before; colour
        // notation is now ASCII-digit only (FR-003-14), so these are plain text.
        "rgb(٣,٣,٣)", "rgb(１,２,３)", "rgb(1,2,٣)", "rgb(1,2%,٣)", "rgba(1 2 3 / ٣)", "rgba(1/٣,1)", "hsl(１２０, 50%, 50%)",
        "hsl(120, ٥٠%, 50%)",
        // names and ordinary text
        "red", "rebeccapurple", "transparent", "colour", "rgb", "hsl", "rgb(", "()", "(1,2,3)", "1,2,3", "1 2 3",
        "hello world", "#hello", "the colour #fff", "see rgb(1,2,3)",
    ]

    @Test("colour notations classify as .color")
    func coloursAreColour() {
        for text in Self.colours {
            #expect(TypedTextDetector.detect(text) == .color, "expected .color for \(text.debugDescription)")
        }
    }

    @Test("non-colour inputs do not classify as .color")
    func nonColoursAreNotColour() {
        for text in Self.notColours {
            #expect(TypedTextDetector.detect(text) != .color, "expected not .color for \(text.debugDescription)")
        }
    }

    // FR-003-14: hsl() and hsla() are a colour item with no swatch.
    @Test("FR-003-14 hsl() and hsla() are .color and carry no swatch channels")
    func hslIsColourWithoutSwatch() {
        for text in ["hsl(120, 50%, 50%)", "hsla(120, 50%, 50%, 0.5)", "hsl(120 50% 50% / 0.5)", "HSL(1,2,3)"] {
            #expect(TypedTextDetector.detect(text) == .color, "\(text)")
            #expect(ColorChannels(text: text) == nil, "\(text)")
        }
    }

    // FR-003-14 (decided, TASK-418): a number too large for a Double (309+ ASCII digits) is infinite, and a non-finite
    // number is not a colour. The pre-refactor regex took any digit run and called these colours; that changed on purpose.
    @Test("FR-003-14 an argument of 309 or more digits is plain text, not a colour, in every function notation")
    func overflowingNumberIsNotColour() {
        let huge = String(repeating: "9", count: 400)
        let justOver = String(repeating: "9", count: 309)
        let justUnder = String(repeating: "9", count: 308)
        for text in ["rgb(\(huge),2,3)", "rgba(1,2,3,\(huge))", "hsl(1,2,\(huge)%)", "rgb(\(justOver) 2 3)"] {
            #expect(!ColorChannels.isNotation(text), "\(text.prefix(24))")
            #expect(TypedTextDetector.detect(text) != .color, "\(text.prefix(24))")
            #expect(ColorChannels(text: text) == nil, "\(text.prefix(24))")
        }
        // 308 digits still fits a Double: still a colour, clamped to 255.
        #expect(ColorChannels.isNotation("rgb(\(justUnder),2,3)"))
        #expect(TypedTextDetector.detect("rgb(\(justUnder),2,3)") == .color)
        #expect(ColorChannels(text: "rgb(\(justUnder),2,3)") == ColorChannels(red: 255, green: 2, blue: 3))
    }
}
