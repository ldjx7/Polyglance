import Foundation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LaunchAtLoginError: LocalizedError, Equatable {
    case requiresApproval
    case registrationDidNotTakeEffect

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return "开机自启需要在系统设置的“登录项与扩展”中允许 Polyglance。"
        case .registrationDidNotTakeEffect:
            return "系统没有成功启用 Polyglance 开机自启，请确认应用已放入“应用程序”目录后重试。"
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
struct LaunchAtLoginManager {
    private let service: any LaunchAtLoginServicing

    init() {
        service = SystemLaunchAtLoginService()
    }

    init(service: any LaunchAtLoginServicing) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func enable() throws {
        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            service.openSystemSettings()
            throw LaunchAtLoginError.requiresApproval
        case .notRegistered, .notFound:
            try service.register()
        }

        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            service.openSystemSettings()
            throw LaunchAtLoginError.requiresApproval
        case .notRegistered, .notFound:
            throw LaunchAtLoginError.registrationDidNotTakeEffect
        }
    }

    private func disable() throws {
        switch service.status {
        case .notRegistered, .notFound:
            return
        case .enabled, .requiresApproval:
            try service.unregister()
        }
    }
}

@MainActor
private final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
