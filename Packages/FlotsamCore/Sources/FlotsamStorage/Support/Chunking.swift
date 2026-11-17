extension Array {
    /// Consecutive slices of at most `size` elements. Batches deletes and statements so none holds the writer, or
    /// SQLite's variable limit, for longer than intended (FR-007-09, FR-007-15).
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
