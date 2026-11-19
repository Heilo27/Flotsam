import Foundation

/// Editing for the two bundle-identifier lists (FR-008-06, FR-008-11).
extension BundleIdentifierList {
    /// A bundle identifier read from a chosen application, or `SET-VAL-002` when there is none (FR-008-11).
    public static func validated(_ raw: String?) -> FlotsamResult<String> {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, !id.contains(where: \.isWhitespace) else {
            return .failure(FlotsamError(.setVal002, "Chosen item has no usable bundle identifier"))
        }
        return .success(id)
    }

    /// Adds `id` at the end; a duplicate is ignored silently.
    public func adding(_ id: String) -> BundleIdentifierList {
        identifiers.contains(id) ? self : BundleIdentifierList(identifiers + [id])
    }

    /// Adds every identifier of `other` that is not already present, keeping the existing order; the user's own entries
    /// are never removed or reordered (FR-008-11 preset).
    public func adding(contentsOf other: BundleIdentifierList) -> BundleIdentifierList {
        other.identifiers.reduce(self) { $0.adding($1) }
    }

    public func removing(_ id: String) -> BundleIdentifierList {
        BundleIdentifierList(identifiers.filter { $0 != id })
    }
}
