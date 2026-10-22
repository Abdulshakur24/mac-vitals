import AppKit
import XCTest
@testable import Vitals

@MainActor
final class AppQuitTests: XCTestCase {
    private final class Application: QuitApplication {
        var processIdentifier: pid_t
        var bundleURL: URL?
        var isTerminated = false
        var acceptsQuit = true
        var acceptsForceQuit = true
        var quits = 0
        var forceQuits = 0

        init(pid: pid_t = 42, path: String = "/Applications/Example.app") {
            processIdentifier = pid
            bundleURL = URL(fileURLWithPath: path)
        }

        func terminate() -> Bool { quits += 1; return acceptsQuit }
        func forceTerminate() -> Bool { forceQuits += 1; return acceptsForceQuit }
    }

    private func group(pids: [pid_t] = [42, 43], path: String = "/Applications/Example.app") -> ProcessGroup {
        let app = ProcessApp(bundleURL: URL(fileURLWithPath: path), name: "Example")
        return ProcessGroup.aggregate(pids.map {
            ProcessInfoRow(pid: $0, started: 100, name: "Example", cpu: 0, memory: 0, app: app)
        })[0]
    }

    private func controller(_ applications: [Application], ownPID: pid_t = 999,
                            identity: ((pid_t) -> ProcessIdentity?)? = nil) -> AppQuitController {
        AppQuitController(runningApplications: { applications },
                          identity: identity ?? { ProcessIdentity(pid: $0, started: 100) }, ownPID: ownPID)
    }

    func testPrepareDoesNotQuitAndNormalQuitNeverEscalates() throws {
        let application = Application()
        application.acceptsQuit = false
        let controller = controller([application])
        let request = try controller.prepare(group())
        XCTAssertEqual(application.quits, 0)
        XCTAssertEqual(application.forceQuits, 0)
        let result = controller.perform(request, mode: .quit)
        XCTAssertEqual(result.failures, [.rejected])
        XCTAssertEqual(application.quits, 1)
        XCTAssertEqual(application.forceQuits, 0)
    }

    func testQuitAndForceUseDistinctRequestsAndReportAcceptance() throws {
        let application = Application()
        let controller = controller([application])
        let request = try controller.prepare(group())
        XCTAssertEqual(controller.perform(request, mode: .quit).requested, 1)
        XCTAssertEqual(controller.perform(request, mode: .forceQuit).requested, 1)
        XCTAssertEqual(application.quits, 1)
        XCTAssertEqual(application.forceQuits, 1)
        XCTAssertFalse(application.isTerminated)
        let feedback = AppQuitController.feedback(for: .init(requested: 1), request: request, mode: .quit)
        XCTAssertTrue(feedback.message.contains("requested"))
        XCTAssertFalse(feedback.message.contains("has already exited"))
        XCTAssertFalse(feedback.isError)
    }

    func testBundleGroupingDoesNotQuitHelpersOrAnotherInstallation() throws {
        let main = Application()
        let second = Application(pid: 44)
        let helper = Application(pid: 43, path: "/Applications/Example.app/Contents/Frameworks/Helper.app")
        let other = Application(pid: 45, path: "/Users/test/Applications/Example.app")
        let controller = controller([main, helper, other, second])
        let request = try controller.prepare(group(pids: [42, 43, 44]))
        XCTAssertEqual(request.instances.count, 2)
        XCTAssertTrue(request.confirmationMessage.contains("2 running instances"))
        XCTAssertEqual(controller.perform(request, mode: .forceQuit).requested, 2)
        XCTAssertEqual(main.forceQuits, 1)
        XCTAssertEqual(second.forceQuits, 1)
        XCTAssertEqual(helper.forceQuits, 0)
        XCTAssertEqual(other.forceQuits, 0)
    }

    func testSelfStandaloneAndMissingApplicationsCannotBeQuit() {
        let application = Application()
        let controller = controller([application], ownPID: 42)
        XCTAssertFalse(controller.canQuit(group()))
        XCTAssertThrowsError(try controller.prepare(group())) { XCTAssertEqual($0 as? AppQuitError, .selfApp) }
        let standalone = ProcessGroup.aggregate([ProcessInfoRow(pid: 50, started: 1, name: "service", cpu: 0, memory: 0)])[0]
        XCTAssertFalse(controller.canQuit(standalone))
        XCTAssertThrowsError(try controller.prepare(standalone)) { XCTAssertEqual($0 as? AppQuitError, .unavailable) }
        XCTAssertThrowsError(try self.controller([]).prepare(group())) { XCTAssertEqual($0 as? AppQuitError, .unavailable) }
        XCTAssertEqual(application.quits, 0)
    }

    func testPIDReuseAndUnreadableIdentityAreRejectedBeforePreparation() {
        let application = Application()
        for started: UInt64? in [200, nil] {
            let controller = controller([application], identity: { pid in started.map { ProcessIdentity(pid: pid, started: $0) } })
            XCTAssertThrowsError(try controller.prepare(group())) { XCTAssertEqual($0 as? AppQuitError, .changed) }
        }
        XCTAssertEqual(application.forceQuits, 0)
    }

    func testRestartOrChangedBundleDuringConfirmationDoesNotQuitAnything() throws {
        let application = Application()
        var started: UInt64 = 100
        let controller = controller([application], identity: { .init(pid: $0, started: started) })
        let request = try controller.prepare(group())
        started = 200
        XCTAssertEqual(controller.perform(request, mode: .forceQuit).failures, [.changed])
        started = 100
        application.bundleURL = URL(fileURLWithPath: "/Applications/Different.app")
        XCTAssertEqual(controller.perform(request, mode: .forceQuit).failures, [.changed])
        XCTAssertEqual(application.forceQuits, 0)
    }

    func testExitedAppIsNotReplacedByRelaunchedInstance() throws {
        let old = Application()
        let replacement = Application(pid: 44)
        var running: [any QuitApplication] = [old]
        let controller = AppQuitController(runningApplications: { running }, identity: { .init(pid: $0, started: 100) }, ownPID: 999)
        let request = try controller.prepare(group())
        old.isTerminated = true
        running = [replacement]
        let result = controller.perform(request, mode: .forceQuit)
        XCTAssertEqual(result.alreadyExited, 1)
        XCTAssertEqual(result.requested, 0)
        XCTAssertEqual(replacement.forceQuits, 0)
        XCTAssertEqual(old.forceQuits, 0)
    }

    func testPartialFailureIsReportedWithoutClaimingAllInstancesClosed() throws {
        let first = Application()
        let second = Application(pid: 44)
        second.acceptsForceQuit = false
        let controller = controller([first, second])
        let request = try controller.prepare(group(pids: [42, 44]))
        let result = controller.perform(request, mode: .forceQuit)
        XCTAssertEqual(result.requested, 1)
        XCTAssertEqual(result.failures, [.rejected])
        let feedback = AppQuitController.feedback(for: result, request: request, mode: .forceQuit)
        XCTAssertTrue(feedback.isError)
        XCTAssertTrue(feedback.message.contains("1 instance"))
    }

    /// Optional integration check uses only a dedicated empty app supplied by
    /// the development harness; it never chooses a user's running app.
    func testQuitAndForceQuitDisposableApp() async throws {
        guard let path = ProcessInfo.processInfo.environment["VITALS_QUIT_FIXTURE"] else {
            throw XCTSkip("Set VITALS_QUIT_FIXTURE to a disposable test app")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        XCTAssertEqual(url.lastPathComponent, "VitalsQuitFixture.app")
        guard url.lastPathComponent == "VitalsQuitFixture.app" else { return }
        for mode in [AppQuitMode.quit, .forceQuit] {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.createsNewApplicationInstance = true
            config.addsToRecentItems = false
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            defer { if !application.isTerminated { _ = application.forceTerminate() } }
            XCTAssertEqual(application.bundleURL?.standardizedFileURL, url)
            let identity = try XCTUnwrap(AppQuitController.processIdentity(application.processIdentifier))
            let app = ProcessApp(bundleURL: url, name: "VitalsQuitFixture")
            let group = ProcessGroup.aggregate([ProcessInfoRow(pid: identity.pid, started: identity.started,
                                                             name: app.name, cpu: 0, memory: 0, app: app)])[0]
            let controller = AppQuitController(runningApplications: { [application] })
            let request = try controller.prepare(group)
            XCTAssertEqual(controller.perform(request, mode: mode).requested, 1)
            for _ in 0..<100 {
                if application.isTerminated { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(application.isTerminated)
        }
    }
}
