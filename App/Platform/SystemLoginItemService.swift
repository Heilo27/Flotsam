import FlotsamBase
import Foundation
import ServiceManagement

/// `SMAppService.mainApp` behind the `LoginItemService` port (FR-008-15). The status is read from macOS each time.
struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .off
        }
    }

    func register() -> FlotsamResult<Void> { attempt { try SMAppService.mainApp.register() } }
    func unregister() -> FlotsamResult<Void> { attempt { try SMAppService.mainApp.unregister() } }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// A refusal (for example a build outside /Applications) is `SET-OS-001`; the system's error carries nothing the
    /// user can act on beyond that, so only its domain and code are kept.
    private func attempt(_ operation: () throws -> Void) -> FlotsamResult<Void> {
        do {
            try operation()
            return .success(())
        } catch {
            let nsError = error as NSError
            return .failure(
                FlotsamError(
                    .setOs001, "Launch at login change was refused",
                    underlying: UnderlyingErrorInfo(domain: nsError.domain, code: nsError.code)))
        }
    }
}
