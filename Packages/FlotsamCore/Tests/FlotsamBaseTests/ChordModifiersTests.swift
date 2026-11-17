import Testing
@testable import FlotsamBase

/// TASK-376 (X083-X090): the ChordModifiers raw bit values are persisted/serialised, so they are pinned as literals.
/// No FRD-000 OC covers this (oracle gap); mapping is to the mutants in `.claude/oracle/frd-000-mutation.json`.
@Suite struct ChordModifiersTests {
    // Kills X083 (command 2<<0), X084 (command 1<<1).
    @Test func commandRawValueIsExactlyOne() {
        // given the command flag, when read, then its stored bit is 1
        #expect(ChordModifiers.command.rawValue == 1)
    }

    // Kills X084 (collides with control), X085 (control 2<<1), X086 (control 1<<2).
    @Test func controlRawValueIsExactlyTwo() {
        #expect(ChordModifiers.control.rawValue == 2)
    }

    // Kills X086 (collides with option), X087 (option 2<<2), X088 (option 1<<3).
    @Test func optionRawValueIsExactlyFour() {
        #expect(ChordModifiers.option.rawValue == 4)
    }

    // Kills X088 (collides with shift), X089 (shift 2<<3), X090 (shift 1<<4).
    @Test func shiftRawValueIsExactlyEight() {
        #expect(ChordModifiers.shift.rawValue == 8)
    }

    // Kills every collision mutant (X084, X086, X088) independently of the literal pins.
    @Test func fourFlagsAreDistinctSingleBitAndDisjoint() {
        let flags: [ChordModifiers] = [.command, .control, .option, .shift]
        #expect(Set(flags).count == 4)
        for flag in flags {
            #expect(flag.rawValue.nonzeroBitCount == 1)
        }
        for i in flags.indices {
            for j in flags.indices where i != j {
                #expect(flags[i].intersection(flags[j]).isEmpty)
            }
        }
        // union of all four uses exactly bits 0-3
        #expect(ChordModifiers([.command, .control, .option, .shift]).rawValue == 15)
    }

    // Combination round-trips: literal raw in, literal membership out, and back.
    @Test func combinationsRoundTripThroughRawValue() {
        let cases: [(ChordModifiers, UInt8)] = [
            ([], 0),
            ([.command], 1),
            ([.command, .shift], 9),
            ([.control, .option], 6),
            ([.command, .control, .option], 7),
            ([.command, .control, .option, .shift], 15),
        ]
        for (flags, raw) in cases {
            #expect(flags.rawValue == raw)
            #expect(ChordModifiers(rawValue: raw) == flags)
        }
    }

    @Test func rawValueFiveMeansCommandAndOptionOnly() {
        let decoded = ChordModifiers(rawValue: 5)
        #expect(decoded.contains(.command))
        #expect(decoded.contains(.option))
        #expect(!decoded.contains(.control))
        #expect(!decoded.contains(.shift))
    }

    // Boundary: the first bit beyond the four flags is not any named flag (max+1).
    @Test func bitBeyondTheFourFlagsMatchesNoNamedFlag() {
        let beyond = ChordModifiers(rawValue: 16)
        for flag: ChordModifiers in [.command, .control, .option, .shift] {
            #expect(!beyond.contains(flag))
        }
    }

    @Test func chordKeepsItsModifiersDistinguishable() {
        let a = Chord(keyCode: 9, modifiers: [.command, .shift])
        let b = Chord(keyCode: 9, modifiers: [.command, .option])
        #expect(a != b)
        #expect(a.modifiers.rawValue == 9)
        #expect(b.modifiers.rawValue == 5)
    }
}
