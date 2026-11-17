import FlotsamBase
import FlotsamStorage
import Foundation
import Observation

/// Composition root: builds the long-lived objects once at launch. Failure here is the Fatal path
/// (STO-IO-002 / STO-DB-003); the alert and quit behaviour (FR-000-04) arrive with the FRD-000 build ticket.
@MainActor
@Observable
final class AppContainer {
    private(set) var database: FlotsamDatabase?
    private(set) var startupError: FlotsamError?

    init() {
        Task { await openDatabase() }
    }

    private func openDatabase() async {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flotsam", isDirectory: true)
        switch await FlotsamDatabase.open(folder: folder) {
        case .success(let opened): database = opened
        case .failure(let error): startupError = error
        }
    }
}
