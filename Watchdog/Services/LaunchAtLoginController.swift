import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case requiresApproval
    case notFound
    case notRegistered
    case unknown
}

@MainActor
protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let service: any LaunchAtLoginServicing

    private enum Keys {
        static let userOptedOut = "launchAtLogin.userOptedOut"
    }

    init(
        defaults: UserDefaults = .standard,
        service: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        automaticallyRegister: Bool = true
    ) {
        self.defaults = defaults
        self.service = service
        refresh()
        if automaticallyRegister {
            registerByDefaultIfNeeded()
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                defaults.removeObject(forKey: Keys.userOptedOut)
            } else {
                try service.unregister()
                defaults.set(true, forKey: Keys.userOptedOut)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refresh() {
        switch service.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
        case .notFound, .notRegistered, .unknown:
            isEnabled = false
            requiresApproval = false
        }
    }

    func registerByDefaultIfNeeded() {
        guard !defaults.bool(forKey: Keys.userOptedOut), service.status == .notRegistered else {
            return
        }

        do {
            try service.register()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
