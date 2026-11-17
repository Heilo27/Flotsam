import FlotsamBase
import FlotsamStorage
import Foundation
import Observation

/// Composition root: builds the long-lived objects once at launch. Failure here is the Fatal path
/// (STO-IO-002 / STO-DB-003); `FatalAlert` shows the alert and quits (FR-000-04).
@MainActor
@Observable
final class AppContainer {
    private(set) var database: FlotsamDatabase?
    private(set) var startupError: FlotsamError?

    init() {
        Task { await openDatabase() }
    }

    /// The data folder, also what the Fatal alert reveals. One definition so "reveal" always opens the folder the
    /// database was attempted in.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotsam", isDirectory: true)
    }

    private func openDatabase() async {
        switch await FlotsamDatabase.open(folder: Self.dataFolder) {
        case .success(let opened): database = opened
        case .failure(let error): startupError = error
        }
    }
}
