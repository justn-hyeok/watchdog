import XCTest
@testable import Watchdog

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "dev.justn.watchdog.launch-at-login-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFirstLaunchRegistersAutomatically() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testApprovalStateIsShownWithoutRepeatedRegistration() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testUnknownStateDoesNotAttemptRegistration() {
        let service = FakeLaunchAtLoginService(status: .unknown)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testExplicitOptOutSurvivesTheNextLaunch() {
        let firstService = FakeLaunchAtLoginService(status: .enabled)
        let firstController = LaunchAtLoginController(defaults: defaults, service: firstService)
        firstController.setEnabled(false)

        let secondService = FakeLaunchAtLoginService(status: .notRegistered)
        _ = LaunchAtLoginController(defaults: defaults, service: secondService)

        XCTAssertEqual(secondService.registerCallCount, 0)
    }

    func testReenablingClearsExplicitOptOut() {
        defaults.set(true, forKey: "launchAtLogin.userOptedOut")
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin.userOptedOut"))
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
