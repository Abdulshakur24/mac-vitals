import Foundation
import ServiceManagement

/// Launch-at-login registration.
///
/// `SMAppService` is the supported route on macOS 13+, but it is picky: it
/// wants the app to live in a stable location and to carry a code signature,
/// and it silently refuses when run from a bare SwiftPM build directory. When
/// it fails, a plain LaunchAgent plist does the same job with no signature
/// requirements at all, so the feature degrades instead of disappearing.
enum LoginItem {
    private static let label = "com.ashakur.vitals"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                // Registering can report success while leaving the service in
                // `requiresApproval` — the app only actually starts at login
                // once it is approved. Fall back so the behaviour the user
                // asked for happens regardless.
                if SMAppService.mainApp.status != .enabled {
                    installLaunchAgent()
                }
            } catch {
                installLaunchAgent()
            }
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    /// Human-readable state, for the command-line switches.
    static func describeStatus() -> String {
        let agent = FileManager.default.fileExists(atPath: launchAgentURL.path)
        let service: String
        switch SMAppService.mainApp.status {
        case .enabled: service = "enabled"
        case .requiresApproval: service = "requires approval in System Settings"
        case .notRegistered: service = "not registered"
        case .notFound: service = "not found"
        @unknown default: service = "unknown"
        }
        return "SMAppService \(service); LaunchAgent \(agent ? "installed" : "absent")"
    }

    private static func installLaunchAgent() {
        let executable = Bundle.main.bundleURL.path
        let directory = launchAgentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/usr/bin/open</string>
        \t\t<string>\(executable)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        </dict>
        </plist>
        """

        try? plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
    }
}
