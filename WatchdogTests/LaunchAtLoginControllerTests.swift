import XCTest
@testable import Watchdog

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testFirstLaunchRegistersAutomatically() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notRegistered)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testApprovalStateIsShownWithoutRepeatedRegistration() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .requiresApproval)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testUnknownStateDoesNotAttemptRegistration() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .unknown)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testExplicitOptOutSurvivesTheNextLaunch() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstService = FakeLaunchAtLoginService(status: .enabled)
        let firstController = LaunchAtLoginController(defaults: defaults, service: firstService)
        firstController.setEnabled(false)

        let secondService = FakeLaunchAtLoginService(status: .notRegistered)
        _ = LaunchAtLoginController(defaults: defaults, service: secondService)

        XCTAssertEqual(secondService.registerCallCount, 0)
    }

    func testReenablingClearsExplicitOptOut() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.userOptedOut")
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin.userOptedOut"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "dev.justn.watchdog.launch-at-login-tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
