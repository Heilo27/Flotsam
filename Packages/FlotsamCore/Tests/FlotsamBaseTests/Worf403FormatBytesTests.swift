import Foundation
import Testing
@testable import FlotsamBase

// Worf, TASK-403 (W-398-3), blind. The formatBytes doc comment claims: a negative size reads as 0, zero reads in digits
// as "0 bytes" (never the word "Zero KB"), and 10 MiB reads "10 MB". Literals only.
@Suite struct Worf403FormatBytesTests {
    // Red if `max(0, bytes)` is dropped, if `allowsNonnumericFormatting = false` is dropped ("Zero KB"), or if the
    // count style stops being binary memory units.
    @Test func formatBytesMatchesItsDocComment() {
        #expect(MessageArgument.formatBytes(0) == "0 bytes")
        #expect(MessageArgument.formatBytes(-1) == "0 bytes")
        #expect(MessageArgument.formatBytes(Int.min) == "0 bytes")
        #expect(MessageArgument.formatBytes(1) == "1 byte")
        #expect(MessageArgument.formatBytes(1_023) == "1,023 bytes")
        #expect(MessageArgument.formatBytes(1_024) == "1 KB")
        #expect(MessageArgument.formatBytes(10_485_760) == "10 MB")
        #expect(MessageArgument.formatBytes(10_485_761) == "10 MB")
    }
}
