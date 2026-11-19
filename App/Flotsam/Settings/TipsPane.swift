import FlotsamBase
import SwiftUI

/// Tips (FR-008-27): a short, static list of the Library's and the Shelf's shortcuts. It reads no setting and writes none.
struct TipsPane: View {
    let model: SettingsModel

    private static let tips: [(title: SettingsString, body: SettingsString)] = [
        (.tipRecallTitle, .tipRecallBody),
        (.tipPasteTitle, .tipPasteBody),
        (.tipPreviewTitle, .tipPreviewBody),
        (.tipMoveTitle, .tipMoveBody),
        (.tipSnippetTitle, .tipSnippetBody),
        (.tipShelfTitle, .tipShelfBody),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(Self.tips.enumerated()), id: \.offset) { _, tip in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tip.title).font(.headline)
                        Text(tip.body).settingsCaption()
                    }
                }
            }
        }
        .settingsPaneChrome()
    }
}
