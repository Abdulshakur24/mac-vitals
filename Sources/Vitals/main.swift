import AppKit

// `--probe` prints a few samples to stdout and exits. It exists so every
// sampler can be checked against Activity Monitor, netstat and ioreg without
// having to read numbers off the menu bar.
if CommandLine.arguments.contains("--probe") {
    Probe.run()
    exit(0)
}

// Launch-at-login can also be toggled from the status item's right-click menu;
// these exist so it can be set up from a terminal or a setup script too.
if CommandLine.arguments.contains("--enable-login") {
    LoginItem.setEnabled(true)
    print("launch at login: \(LoginItem.describeStatus())")
    exit(0)
}

if CommandLine.arguments.contains("--disable-login") {
    LoginItem.setEnabled(false)
    print("launch at login: \(LoginItem.describeStatus())")
    exit(0)
}

if CommandLine.arguments.contains("--login-status") {
    print("launch at login: \(LoginItem.describeStatus())")
    exit(0)
}

// Plain AppKit bootstrap rather than a SwiftUI `@main App`. Under SwiftPM a
// file named main.swift gives us top-level code without the `-parse-as-library`
// dance, and `.accessory` keeps the app out of the Dock and the app switcher.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
