import AppKit
import Darwin

/// Retain the running application selected by the user, rather than resolving
/// its bundle again after a confirmation (which could target a new launch).
@MainActor
protocol QuitApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleURL: URL? { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
    func forceTerminate() -> Bool
}

extension NSRunningApplication: QuitApplication {}

enum AppQuitMode {
    case quit, forceQuit
}

enum AppQuitError: LocalizedError, Equatable {
    case unavailable, selfApp, changed, rejected

    var errorDescription: String? {
        switch self {
        case .unavailable: return "No running app is available for this entry."
        case .selfApp: return "Use Quit at the bottom of the panel to close Vitals."
        case .changed: return "The app changed or restarted. Select it again from the updated list."
        case .rejected: return "macOS could not send the quit request."
        }
    }
}

struct AppQuitRequest {
    struct Instance {
        let application: any QuitApplication
        let identity: ProcessIdentity
    }

    let name: String
    let bundleURL: URL
    let instances: [Instance]

    var confirmationMessage: String {
        let prefix = instances.count > 1 ? "All \(instances.count) running instances will close. " : ""
        return prefix + "Unsaved changes may be lost."
    }
}

struct AppQuitResult: Equatable {
    var requested = 0
    var alreadyExited = 0
    var failures: [AppQuitError] = []
}

struct AppQuitFeedback {
    var message: String
    var isError: Bool
}

@MainActor
final class AppQuitController {
    private let runningApplications: () -> [any QuitApplication]
    private let identity: (pid_t) -> ProcessIdentity?
    private let ownPID: pid_t

    init(runningApplications: @escaping () -> [any QuitApplication] = { NSWorkspace.shared.runningApplications },
         identity: @escaping (pid_t) -> ProcessIdentity? = AppQuitController.processIdentity,
         ownPID: pid_t = getpid()) {
        self.runningApplications = runningApplications
        self.identity = identity
        self.ownPID = ownPID
    }

    func canQuit(_ group: ProcessGroup) -> Bool {
        group.app != nil && !group.processes.contains { $0.pid == ownPID }
    }

    func prepare(_ group: ProcessGroup) throws -> AppQuitRequest {
        guard let app = group.app else { throw AppQuitError.unavailable }
        guard canQuit(group) else { throw AppQuitError.selfApp }
        let url = app.bundleURL.standardizedFileURL
        let candidates = runningApplications().filter {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL == url
        }
        guard !candidates.isEmpty else { throw AppQuitError.unavailable }

        let sampled = Set(group.processes.map(\.id))
        var instances: [AppQuitRequest.Instance] = []
        for application in candidates {
            let pid = application.processIdentifier
            guard pid > 1, pid != ownPID else { throw AppQuitError.selfApp }
            guard let current = identity(pid), sampled.contains(current) else {
                throw AppQuitError.changed
            }
            instances.append(.init(application: application, identity: current))
        }
        return AppQuitRequest(name: group.name, bundleURL: url, instances: instances)
    }

    func perform(_ request: AppQuitRequest, mode: AppQuitMode) -> AppQuitResult {
        var result = AppQuitResult()
        for instance in request.instances {
            let application = instance.application
            if application.isTerminated {
                result.alreadyExited += 1
                continue
            }
            guard instance.identity.pid > 1, instance.identity.pid != ownPID else {
                result.failures.append(.selfApp)
                continue
            }
            // Never substitute a new process if the app exited, relaunched, or
            // changed while its menu or confirmation was open.
            guard application.processIdentifier == instance.identity.pid,
                  application.bundleURL?.standardizedFileURL == request.bundleURL,
                  identity(instance.identity.pid) == instance.identity else {
                result.failures.append(.changed)
                continue
            }
            let accepted = mode == .quit ? application.terminate() : application.forceTerminate()
            if accepted { result.requested += 1 }
            else if application.isTerminated { result.alreadyExited += 1 }
            else { result.failures.append(.rejected) }
        }
        return result
    }

    /// A successful AppKit return means a request was sent, not that the app
    /// has exited. The existing process samples remain the source of truth.
    static func feedback(for result: AppQuitResult, request: AppQuitRequest, mode: AppQuitMode) -> AppQuitFeedback {
        if let error = result.failures.first {
            let noun = result.requested == 1 ? "instance" : "instances"
            let partial = result.requested > 0 ? "Requested for \(result.requested) \(noun). " : ""
            return AppQuitFeedback(message: partial + error.localizedDescription, isError: true)
        }
        if result.requested == 0 {
            return AppQuitFeedback(message: "\(request.name) has already exited.", isError: false)
        }
        let action = mode == .quit ? "Quit" : "Force quit"
        let guidance = mode == .quit ? " Check the app for any save prompts." : ""
        return AppQuitFeedback(message: "\(action) requested for \(request.name)." + guidance, isError: false)
    }

    nonisolated static func processIdentity(_ pid: pid_t) -> ProcessIdentity? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? ProcessIdentity(pid: pid, started: usage.ri_proc_start_abstime) : nil
    }
}
