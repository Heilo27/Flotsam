import FlotsamBase
import FlotsamLibrary
import SwiftUI

/// Types (FR-008-26): which types the Library sidebar and the Shelf pills list, and in what order. A listed type is
/// shown (while it has items); an unlisted one is hidden from the sidebar and the pills, never from All or search.
struct TypesPane: View {
    let model: SettingsModel

    var body: some View {
        let listed = model.value(SettingKeys.libraryTypes).kinds
        let hidden = ItemKind.displayOrder.filter { !listed.contains($0) }
        Form {
            Section {
                ForEach(Array(listed.enumerated()), id: \.element) { index, kind in
                    row(kind, isShown: true, canMoveUp: index > 0, canMoveDown: index < listed.count - 1)
                }
                .onMove { source, destination in
                    var kinds = listed
                    kinds.move(fromOffsets: source, toOffset: destination)
                    write(kinds)
                }
                ForEach(hidden, id: \.self) { kind in
                    row(kind, isShown: false, canMoveUp: false, canMoveDown: false)
                }
                Text(.typesHelp).settingsCaption()
            }
        }
        .settingsPaneChrome()
    }

    private func row(_ kind: ItemKind, isShown: Bool, canMoveUp: Bool, canMoveDown: Bool) -> some View {
        HStack {
            Toggle(isOn: Binding(get: { isShown }, set: { setShown(kind, $0) })) {
                Text(verbatim: LibraryText.typeTitle(kind))
            }
            Spacer()
            Button { move(kind, by: -1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel(Text(.typeMoveUp))
                .disabled(!canMoveUp)
            Button { move(kind, by: 1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(Text(.typeMoveDown))
                .disabled(!canMoveDown)
        }
        .buttonStyle(.borderless)
    }

    private func write(_ kinds: [ItemKind]) {
        model.env.settings.set(TypeOrder(kinds), for: SettingKeys.libraryTypes)
    }

    /// Showing a type puts it at the end of the list; hiding removes it.
    private func setShown(_ kind: ItemKind, _ shown: Bool) {
        var kinds = model.env.settings.value(SettingKeys.libraryTypes).kinds
        kinds.removeAll { $0 == kind }
        if shown { kinds.append(kind) }
        write(kinds)
    }

    private func move(_ kind: ItemKind, by offset: Int) {
        var kinds = model.env.settings.value(SettingKeys.libraryTypes).kinds
        guard let index = kinds.firstIndex(of: kind), kinds.indices.contains(index + offset) else { return }
        kinds.swapAt(index, index + offset)
        write(kinds)
    }
}
