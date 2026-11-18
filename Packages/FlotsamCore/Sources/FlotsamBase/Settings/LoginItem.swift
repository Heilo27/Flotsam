import Foundation

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case off
}

/// `SMAppService.mainApp` behind a port (FR-008-15). The status is owned by macOS and read each time it is needed.
public protocol LoginItemService: Sendable {
    var status: LoginItemStatus { get }
    func register() -> FlotsamResult<Void>
    func unregister() -> FlotsamResult<Void>
    func openLoginItemsSettings()
}

public struct LoginItemController: Sendable {
    private let service: any LoginItemService

    public init(service: any LoginItemService) { self.service = service }

    public var status: LoginItemStatus { service.status }
    /// `.enabled` and `.requiresApproval` both show as on (the second with a caption and a button).
    public var isOn: Bool { service.status != .off }

    public func openLoginItemsSettings() { service.openLoginItemsSettings() }

    /// Registers or unregisters, then returns the status macOS reports. A failure is `SET-OS-001`, for which the caller
    /// shows the HUD and reverts the control.
    public func setEnabled(_ on: Bool) -> FlotsamResult<LoginItemStatus> {
        let result = on ? service.register() : service.unregister()
        return result.map { service.status }
    }

    /// Brings macOS in line with what a switch says, and touches the service only when they differ. A switch that is off
    /// while macOS has no login item makes no `register()` and no `unregister()` call, so no "Login Item Added" banner
    /// can follow an unchecked box (FR-008-15). The one home of that rule for onboarding's Continue.
    public func reconcile(wanted: Bool) -> FlotsamResult<LoginItemStatus> {
        guard wanted != isOn else { return .success(status) }
        return setEnabled(wanted)
    }
}
