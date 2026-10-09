import AppKit
import Combine
import SwiftUI

/// Hosting view that refuses to handle clicks.
///
/// An NSHostingView added to a status item button would otherwise eat the
/// mouse events the button needs to fire its action, leaving an item that
/// renders correctly but does nothing when clicked.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = MetricsEngine()
    private let configStore = ConfigStore()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingView: NSView?

    /// What the readout is drawing right now, which is the configured metrics
    /// minus whatever the menu bar has no room for.
    private let layoutModel = MenuBarLayoutModel()

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

        buildStatusItemContent()
        setMetrics(configStore.config.menuBar)
    }

    /// Installs the readout. Done once: which metrics it draws is published
    /// through `layoutModel` rather than baked into the view, so the shape can
    /// change on every tick without tearing down and rebuilding a hosting view.
    private func buildStatusItemContent() {
        guard let button = statusItem.button else { return }

        hostingView?.removeFromSuperview()

        let hosting = PassthroughHostingView(
            rootView: MenuBarView(engine: engine, layoutModel: layoutModel)
        )
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        hostingView = hosting
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
        layoutModel.layout = ladder[0]
        statusItem.length = ladder[0].width
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
        layoutModel.layout = ladder[rank]
        statusItem.length = ladder[rank].width
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
            .sink { [weak self] _ in self?.updateLayout() }
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

    private func showContextMenu() {
        let menu = NSMenu()

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

        // Attaching the menu makes the click that follows open it, then it is
        // detached again so left-click keeps showing the popover instead.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func revealConfig() {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/vitals/config.json")
        NSWorkspace.shared.open(url)
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
            self?.layoutModel.layout.metrics.contains(.temperature) ?? true
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
        let controller = NSHostingController(rootView: PopoverView(engine: engine))
        // Without this the popover keeps its default content size and the
        // SwiftUI view overflows it — the top sections get clipped straight
        // off. `.preferredContentSize` makes the controller publish SwiftUI's
        // ideal height so the popover sizes itself to the whole panel.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
