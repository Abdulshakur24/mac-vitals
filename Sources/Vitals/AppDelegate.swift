import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSViewToolTipOwner {
    private let engine = MetricsEngine(historyStore: HistoryStore())
    private let configStore = ConfigStore()
    private let panelState = PanelState()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    /// What the readout is drawing right now, which is the configured metrics
    /// minus whatever the menu bar has no room for.
    private var layout = MenuBarLayout(items: [])

    /// The latest published sample. `@Published` delivers before the property
    /// changes, so this is kept from the sink rather than read off the engine.
    private var latest = Snapshot()

    /// What the status button is showing. Touching the button is what costs,
    /// so it is only touched when this would change.
    private var shown: MenuBarReadout?

    /// When the button was last changed, on the `systemUptime` clock.
    private var lastShown: TimeInterval = 0

    /// Shortest gap between button updates, independent of the sample rate.
    ///
    /// Every update makes AppKit snapshot the item for each copy of the menu
    /// bar, and that is what this app's idle CPU is: measured over a minute at
    /// a 1s sample rate, 2.8% updating on every change, 1.1% at 2s, 0.8% at 3s.
    /// Sampling itself is a small fraction of that, so history and the panel
    /// stay at the full rate and only the menu bar digits are held back.
    private static let readoutRefresh: TimeInterval = 3

    /// Every layout the configured metrics can degrade to, richest first.
    /// Rebuilt on config change only, since the widths in it are fixed.
    private var ladder: [MenuBarLayout] = []

    /// How far down the ladder the readout currently is.
    private var layoutRank = 0

    /// A width the window server would not draw, and the menu bar it was
    /// refused on.
    ///
    /// The arithmetic in `StatusItemFit` is a model of where macOS will place
    /// a status item, and a model can be wrong in the one direction that
    /// cannot be seen from inside it: believing a layout fits that macOS then
    /// declines to draw. Nothing about that state is unstable, so it lasts
    /// until something else on the menu bar changes — which is how a readout
    /// stays missing for days while the app goes on agreeing with itself.
    ///
    /// This is the measurement that outranks the model. A refusal is recorded
    /// against the space it happened in, and caps the ladder until that space
    /// changes, at which point the model gets to try again.
    private var refused: (width: CGFloat, occupied: CGFloat)?

    /// How far the space held by other items has to move before a refusal is
    /// treated as stale news about a menu bar that no longer exists.
    ///
    /// Small, because this number only moves when an item actually appears,
    /// leaves, or changes shape — the narrowest of them is wider than this
    /// several times over.
    private static let refusalTolerance: CGFloat = 2

    /// Whether the current layout has been up long enough to be asked about.
    ///
    /// The item's window resizes a beat after `length` is set, so on the tick
    /// a layout changes, the window server is still describing the previous
    /// one. Believing it then would record a refusal against the wrong width.
    private var layoutSettled = false

    /// Longest a sample tick goes without measuring the menu bar, once the
    /// layout has settled.
    ///
    /// The measurement is a round trip to the window server, and profiling
    /// showed it was most of what the app did on a tick — several times the
    /// cost of every sampler put together. Nothing about the menu bar changes
    /// that often. The events that do make it change quickly (an app
    /// activating, a display or Space change) force a measurement of their
    /// own, so this only bounds how long another app's status item can appear
    /// unnoticed.
    private static let measureInterval: TimeInterval = 5

    /// When the menu bar was last measured, on the `systemUptime` clock.
    private var lastMeasured: TimeInterval = 0

    /// What the last measurement said about whether the item is drawn.
    ///
    /// The throttle is for a readout known to be fine. One that is not being
    /// drawn is the state this whole mechanism exists to get out of, and it
    /// does so one rung per measurement, so it is measured on every tick until
    /// the window server says otherwise.
    private var lastDrawn: Bool?

    private var cancellables: Set<AnyCancellable> = []

    func applicationWillTerminate(_ notification: Notification) {
        engine.saveHistory()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.configure(configStore.config)

        setUpStatusItem()
        setUpPopover()
        observeMenuBarSpace()

        configStore.onChange = { [weak self] config in
            self?.apply(config)
        }

        engine.start()

        // Opens the popover without a click. Verifying the detail panel
        // otherwise needs Accessibility permission just to script a click on
        // the status item, which is a lot of ceremony for a screenshot.
        if ProcessInfo.processInfo.environment["VITALS_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.togglePopover()
            }
        }
    }

    private func apply(_ config: Config) {
        engine.configure(config)
        setMetrics(config.menuBar)
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Vitals")

        // Colours resolve when the image draws, but a button with an unchanged
        // image has no reason to draw when the menu bar flips light or dark.
        button.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .sink { [weak self] _ in
                self?.shown = nil
                self?.showReadout()
            }
            .store(in: &cancellables)

        setMetrics(configStore.config.menuBar)
    }

    /// Applies a layout to the status item: the readout and the length change
    /// together, so the button is never drawn at the wrong width.
    private func setLayout(_ newLayout: MenuBarLayout) {
        layout = newLayout
        statusItem.length = newLayout.width
        showReadout()
        // Tooltip regions are fixed rectangles and the button has just resized.
        guard let button = statusItem.button else { return }
        button.removeAllToolTips()
        button.addToolTip(NSRect(x: 0, y: 0, width: newLayout.width, height: MenuBarReadout.height),
                          owner: self, userData: nil)
    }

    /// Updates the button if, and only if, what it shows has changed.
    private func showReadout() {
        guard let button = statusItem.button else { return }
        let readout = MenuBarReadout(layout: layout, snapshot: latest, thresholds: engine.thresholds)
        guard readout != shown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let shown, !readout.isUrgent(comparedTo: shown),
           now - lastShown < Self.readoutRefresh { return }
        lastShown = now
        shown = readout
        button.image = MenuBarRenderer.image(for: readout)
        button.setAccessibilityValue(latest.summary)
    }

    /// Asked for when the tooltip appears, so nothing is built on each sample.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        latest.summary
    }

    // MARK: - Fitting the readout to the space there is

    /// Slack a richer layout has to fit within before it is adopted.
    ///
    /// Only expanding is held to it, so the readout gives way immediately and
    /// takes space back only once there is clearly enough. Without it, a layout
    /// adopted at exactly the width available would be at the mercy of a
    /// neighbouring item shifting by a point, and would swap shape back and
    /// forth for as long as the bar stayed near that boundary.
    private static let growthMargin: CGFloat = 12

    /// Takes a new metric list from the config file and re-fits it.
    private func setMetrics(_ metrics: [Metric]) {
        ladder = MenuBarLayout.ladder(for: metrics)
        layoutRank = 0
        setLayout(ladder[0])
        // A refusal is about a width, and these are new widths.
        refused = nil
        layoutSettled = false
        updateLayout()
    }

    /// Picks the richest layout the menu bar currently has room for.
    ///
    /// The arithmetic is trivial — a subtraction and a walk of at most a couple
    /// of dozen precomputed widths. What costs is the window list it reads,
    /// which is why measuring is throttled.
    ///
    /// `force` skips the throttle, for the events that can change the space.
    /// A layout that has just changed is not throttled either: the window
    /// server describes the old width for a beat, so it is looked at again on
    /// the next tick to find out whether the new one was drawn. Nor is an item
    /// that was found not to be drawn.
    private func updateLayout(force: Bool = false) {
        guard !ladder.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force, layoutSettled, lastDrawn != false,
           now - lastMeasured < Self.measureInterval { return }

        // No screen to measure against — a display mid-departure. The next
        // sample corrects it either way.
        guard let fit = StatusItemFit.measure(for: statusItem) else { return }
        lastMeasured = now
        lastDrawn = fit.isDrawn

        // A refusal describes one arrangement of the menu bar. Once the space
        // has moved, it is describing something that is no longer there.
        if let refused, abs(refused.occupied - fit.occupied) > Self.refusalTolerance {
            self.refused = nil
            trace("fit: menu bar changed, dropping refusal of \(Int(refused.width))")
        }

        // The layout that is up is not being drawn, and the arithmetic thinks
        // it should be. The window server is the one that decides.
        if fit.isDrawn == false, layoutSettled {
            let width = ladder[layoutRank].width
            if refused?.width != width {
                refused = (width, fit.occupied)
                trace("fit: refused width=\(Int(width)) at occupied=\(Int(fit.occupied))")
            }
        }

        // Never ask for a width already known to be refused in this space.
        var budget = fit.available
        if let refused { budget = min(budget, refused.width - 1) }

        let rank: Int
        if ladder[layoutRank].width > budget {
            // Out of room now. Give up as little as will fit.
            rank = MenuBarLayout.fittingIndex(in: ladder, within: budget)
        } else {
            // Room to spare, so take some back — but only what stays fitting
            // with the margin to spare, and never less than what is already up.
            let grown = MenuBarLayout.fittingIndex(in: ladder, within: budget - Self.growthMargin)
            guard grown < layoutRank else { layoutSettled = true; return }
            rank = grown
        }

        guard rank != layoutRank else { layoutSettled = true; return }
        layoutRank = rank
        setLayout(ladder[rank])
        layoutSettled = false

        let shape = ladder[rank].items
            .map { "\($0.metric.rawValue)\($0.style == .compact ? "*" : "")" }
            .joined(separator: " ")
        trace("fit: available=\(Int(fit.available)) budget=\(Int(budget)) width=\(Int(ladder[rank].width)) [\(shape)]")
    }

    /// How the readout is giving ground is otherwise only observable by
    /// staring at the menu bar and hoping to catch it.
    private func trace(_ line: String) {
        guard ProcessInfo.processInfo.environment["VITALS_FIT_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Re-fits whenever the space available can have changed.
    ///
    /// Nothing reports that the menu bar got tighter, so this watches the
    /// things that make it happen — another app's menu titles taking the width
    /// on activation, a display arriving or leaving, a different Space — and
    /// piggybacks on the metric samples for everything else, which covers
    /// another app adding or removing a status item within a few seconds.
    /// Deliberately not its own timer: the one-timer rule is what keeps this
    /// app cheap, and re-fitting is not worth a wakeup of its own.
    private func observeMenuBarSpace() {
        engine.$snapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                latest = snapshot
                updateLayout()
                showReadout()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification
        )
        .sink { [weak self] _ in self?.updateLayout(force: true) }
        .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            workspace.publisher(for: name)
                .sink { [weak self] _ in self?.updateLayout(force: true) }
                .store(in: &cancellables)
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// One menu for right-clicking the status item and the panel's gear.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let monitor = NSMenuItem(
            title: "Activity Monitor",
            action: #selector(openActivityMonitor),
            keyEquivalent: ""
        )
        monitor.target = self
        menu.addItem(monitor)

        let reveal = NSMenuItem(
            title: "Edit Configuration…",
            action: #selector(revealConfig),
            keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        let login = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Vitals",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private func showContextMenu() {
        // Attaching the menu makes the click that follows open it, then it is
        // detached again so left-click keeps showing the popover instead.
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func openSettings() {
        panelState.showsSettings = true
        if !popover.isShown { togglePopover() }
    }

    @objc private func revealConfig() {
        let url = configStore.url
        // Nothing may be registered for .json on a Mac with no code editor, and
        // `open` fails silently then. Finder at least shows where the file is.
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func openActivityMonitor() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opened at the pointer rather than attached to the gear: the panel is
    /// SwiftUI and `NSMenu` is what the status item already builds.
    private func showPanelMenu() {
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // MARK: - Popover

    private func setUpPopover() {
        // Let AppKit supply the system's popover material and appearance.
        // Adding another glass/material background would cover that surface.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false

        engine.isDetailVisible = { [weak popover] in popover?.isShown ?? false }
        // The live layout rather than the config, so a temperature readout
        // dropped for want of space also stops the sensors it would have cost
        // to read. Nothing else in the app is expensive enough to be worth
        // gating this way.
        engine.isTemperatureShown = { [weak self] in
            self?.layout.metrics.contains(.temperature) ?? true
        }

        // `.transient` popovers close on their own when focus moves elsewhere,
        // so the engine learns about it here rather than in the toggle. This
        // is registered once — doing it per open would stack up a duplicate
        // observer on every click.
        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Drop the SwiftUI view entirely. A retained NSHostingController
            // keeps re-evaluating its body on every engine update even while
            // the popover is off screen — profiling showed PopoverView.body
            // running on every tick with nothing visible, which is most of
            // this app's idle cost.
            popover.contentViewController = nil
            panelState.showsSettings = false
            statusItem.button?.highlight(false)
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        engine.prepareDetailSamplers()

        // Built fresh on each open and torn down on close, so the detail view
        // costs nothing at all while hidden.
        let height = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 800
        let controller = NSHostingController(rootView: PopoverView(
            engine: engine,
            config: configStore,
            panel: panelState,
            maxHeight: min(700, height - 40),
            showMenu: { [weak self] in self?.showPanelMenu() },
            editConfig: { [weak self] in self?.revealConfig() }
        ))
        // Without this the popover keeps its default content size and the
        // SwiftUI view overflows it — the top sections get clipped straight
        // off. `.preferredContentSize` makes the controller publish SwiftUI's
        // ideal height so the popover sizes itself to the whole panel.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }
}
