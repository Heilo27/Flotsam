import FlotsamBase
import Foundation
import ServiceManagement

/// `SMAppService.mainApp` behind the `LoginItemService` port (FR-008-15). macOS owns the state; it is read on each call.
struct SMLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    func register() -> FlotsamResult<Void> {
        do {
            try SMAppService.mainApp.register()
            return .success(())
        } catch {
            return .failure(FlotsamError(.setOs001, "Login item register failed", underlying: UnderlyingErrorInfo(error)))
        }
    }

    func unregister() -> FlotsamResult<Void> {
        do {
            try SMAppService.mainApp.unregister()
            return .success(())
        } catch {
            return .failure(FlotsamError(.setOs001, "Login item unregister failed", underlying: UnderlyingErrorInfo(error)))
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
