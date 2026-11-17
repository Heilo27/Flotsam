import FlotsamBase
import Foundation

extension TemplateVariables {
    /// FR-005-18: the same substitution, performed on the attributed string so run attributes survive. A value takes
    /// the attributes of the first character of the text it replaces, so a variable inside a link's text is replaced
    /// inside that link. Runs the substitution does not touch are copied as they are.
    public static func expand(_ text: AttributedString, context: TemplateContext) -> AttributedString {
        let characters = Array(String(text.characters))
        let substitutions: [(range: Range<Int>, value: String)] = scan(characters).compactMap { span in
            replacement(for: span.kind, context: context).map { (span.range, $0) }
        }
        guard !substitutions.isEmpty else { return text }

        var output = AttributedString()
        var copiedUpTo = text.startIndex
        // Spans arrive in order, so one forward-moving probe converts every offset (O(n) overall).
        var probe = text.startIndex
        var probeOffset = 0
        func move(to offset: Int) -> AttributedString.Index {
            probe = text.characters.index(probe, offsetBy: offset - probeOffset)
            probeOffset = offset
            return probe
        }

        for substitution in substitutions {
            let lower = move(to: substitution.range.lowerBound)
            let upper = move(to: substitution.range.upperBound)
            output.append(AttributedString(text[copiedUpTo..<lower]))
            if !substitution.value.isEmpty {
                let attributes = text[lower..<text.characters.index(after: lower)].runs.first?.attributes
                    ?? AttributeContainer()
                output.append(AttributedString(substitution.value, attributes: attributes))
            }
            copiedUpTo = upper
        }
        output.append(AttributedString(text[copiedUpTo...]))
        return limitedToTextCeiling(output)
    }

    private static func limitedToTextCeiling(_ text: AttributedString) -> AttributedString {
        guard let count = characterCountWithinTextCeiling(of: String(text.characters)) else { return text }
        let end = text.characters.index(text.startIndex, offsetBy: count)
        return AttributedString(text[text.startIndex..<end])
    }
}
