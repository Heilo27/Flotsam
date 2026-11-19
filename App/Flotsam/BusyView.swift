import FlotsamBase
import SwiftUI

/// The spinner of a slow load or search (FR-003-50, FR-006-32), shared by the Library and the Shelf. Visibility is the
/// model's `BusyIndicator` (150 ms one-shot); these views only draw it, so a fast load shows nothing at all.

/// Fills its container: blank while `isVisible` is false, else a spinner and its caption, centred.
struct BusyView: View {
    let isVisible: Bool
    let isSearching: Bool

    var body: some View {
        ZStack {
            if isVisible { BusyLabel(isSearching: isSearching) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BusyLabel: View {
    let isSearching: Bool

    var body: some View {
        let caption = BusyIndicator.label(isSearching: isSearching)
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: caption).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption)
    }
}

extension View {
    /// A small capsule at the top of content that is already on screen, while a reload or search is still running.
    func busyBadge(isVisible: Bool, isSearching: Bool) -> some View {
        overlay(alignment: .top) {
            if isVisible {
                BusyLabel(isSearching: isSearching)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }
}
