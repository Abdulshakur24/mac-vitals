import AppKit

/// How much menu bar the status item is actually allowed to occupy.
///
/// macOS gives no direct answer to this. A status item with no room left is
/// not clipped, moved, or marked hidden — `isVisible`, `alphaValue` and
/// `occlusionState` all keep reporting a healthy item while nothing is drawn,
/// and the item's own window keeps a plausible-looking frame whether or not
/// the window server is drawing it. Measuring from that frame is therefore
/// measuring a rumour.
///
/// What the window server does tell the truth about is which windows it is
/// actually drawing: `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` lists
/// every drawn status item as a menu-bar-height window at status level (they
/// are all reported as owned by Control Center, so ownership is no use for
/// finding our own — the window number is). The budget is then simple
/// arithmetic: the status item region runs from the notch (or the menu title
/// allowance) to the screen's right edge, everything drawn in it that is not
/// us is spoken for, and the rest is ours to ask for.
///
/// This stays honest in the states that matter: while our item is drawn, its
/// own width is part of the budget; while it is hidden — the state every other
/// signal misreports — it is absent from the drawn list, so the budget
/// collapses to the actual free gap and the layout degrades until it fits.
enum StatusItemFit {
    /// Assumed width of the frontmost app's menu titles on a display with no
    /// notch, where there is no public way to find where they end.
    ///
    /// Generous rather than exact: the cost of guessing high is a slightly
    /// compacted readout on a screen that had room for the full one, and the
    /// cost of guessing low is the readout disappearing, which is the thing
    /// this is all here to prevent.
    private static let menuTitlesAllowance: CGFloat = 260

    /// Points of slack kept between the readout and the edge of the region, so
    /// a layout chosen at exactly the limit does not lose to rounding.
    private static let safetyMargin: CGFloat = 8

    /// How much of `auxiliaryTopRightArea` macOS declines to use.
    ///
    /// The area reported beside the notch is not all placeable: macOS keeps a
    /// gap after the notch and will not put a status item in it. Nothing
    /// reports the size of that gap, and taking the reported edge at face value
    /// is what made the readout vanish — the arithmetic said a 217pt layout fit
    /// in the space to the notch, macOS refused to draw it, and since the sums
    /// kept agreeing with themselves the ladder never stepped down. An item
    /// that is not drawn stays not drawn, which is the one state this whole
    /// file exists to avoid.
    ///
    /// Measured on this M4, against a reported edge of x=948, by forcing the
    /// layout to a fixed width with `VITALS_FIT_AVAILABLE` and reading back
    /// whether the window server drew the result:
    ///
    ///     x=957  refused      x=970   drawn
    ///     x=958  refused      x=992   drawn
    ///     x=966  refused      x=1002  drawn
    ///
    /// So the gap is between 18 and 22 points, and this takes the far end of
    /// that. With `safetyMargin` on top, the leftmost position the fit can
    /// ever choose — `leftLimit + safetyMargin`, since an adopted layout is at
    /// most `available` wide — is x=978, clear of every refusal seen and left
    /// of nothing that was not observed to draw.
    ///
    /// The two are therefore a pair: raising `safetyMargin` without lowering
    /// this by as much only spends readout on space that measurement says is
    /// usable, and lowering either puts the item left of anything seen drawn.
    private static let notchClearance: CGFloat = 22

    /// The chrome an `NSStatusItem` window adds around its content length.
    private static let assumedChrome: CGFloat = 16

    /// Windows this much taller than the menu bar are not status items —
    /// popovers and panels also live at status level.
    private static let menuBarWindowMaxHeight: CGFloat = 40

    /// What the window server has to say about the item.
    struct Fit {
        /// Width available to the item's content.
        var available: CGFloat

        /// Width the other drawn items are holding.
        ///
        /// Separate from `available` because it is the stable half: it says
        /// nothing about our own window, so it does not move when the readout
        /// changes shape, and it is the honest way to ask whether the menu bar
        /// is still the menu bar a past refusal happened on.
        var occupied: CGFloat

        /// Whether the item is being drawn, or nil when the question has no
        /// useful answer: the menu bar itself is off screen behind a
        /// fullscreen app, or our own window could not be picked out of the
        /// list. Not being drawn means nothing when nothing is.
        var isDrawn: Bool?
    }

    /// Measures `item` against the menu bar, or nil when there is no screen to
    /// measure against.
    ///
    /// Both answers come from one pass over the window list. Asking twice
    /// would double the cost of the only thing this file does every tick, and
    /// the two questions are the same question — the list says who is drawn
    /// and how wide they are, and the item's own row in it is the one that
    /// says whether the arithmetic was believed.
    static func measure(for item: NSStatusItem) -> Fit? {
        // Every rung of the ladder needs to be seen to be trusted, and a menu
        // bar cannot be filled to an exact width on demand — the space depends
        // on whatever else is running. This substitutes a measurement so each
        // one can be looked at directly:
        //
        //     VITALS_FIT_AVAILABLE=130 Vitals
        if let forced = ProcessInfo.processInfo.environment["VITALS_FIT_AVAILABLE"],
           let value = Double(forced) {
            // A forced width is there to hold a chosen layout still and see
            // what becomes of it, so the backstop must not then take it away.
            return Fit(available: CGFloat(value), occupied: 0, isDrawn: nil)
        }

        // The state the backstop exists for is the hardest one to arrange on
        // demand: it needs a menu bar with no room left in it, and a status
        // item macOS will not simply make room for by dropping a neighbour.
        // Claiming the refusal instead runs the descent for real — every rung
        // recorded, capped, and stepped past — against whatever is up:
        //
        //     VITALS_FIT_UNDRAWN=1 Vitals
        let claimUndrawn = ProcessInfo.processInfo.environment["VITALS_FIT_UNDRAWN"] == "1"

        let window = item.button?.window
        guard let screen = window?.screen ?? NSScreen.main else { return nil }

        let leftLimit: CGFloat
        if let notchArea = screen.auxiliaryTopRightArea {
            // Everything from here rightwards is status item territory; the
            // notch and the app menus beyond it are not. Not quite all of it
            // is placeable, hence the clearance.
            leftLimit = notchArea.minX + notchClearance
        } else {
            leftLimit = screen.frame.minX + menuTitlesAllowance
        }
        let rightLimit = screen.frame.maxX

        // The menu bar's top edge in the global top-left-origin coordinates
        // CGWindowList reports, which differ from AppKit's only in flipping y
        // around the primary screen's top.
        guard let primary = NSScreen.screens.first else { return nil }
        let menuBarY = primary.frame.maxY - screen.frame.maxY

        // The whole list rather than the drawn part of it: an item that is not
        // being drawn still has a row here, and that row is the only place the
        // window server admits to having dropped it.
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

        // Our own drawn window is identified by its frame — the window numbers
        // the window server reports for status items do not match
        // `NSWindow.windowNumber`, so geometry is the only usable identity.
        let ownFrame = window?.frame
        var ownDrawn: Bool?
        var anyDrawn = false

        var occupied: CGFloat = 0
        for info in list {
            guard let layer = info["kCGWindowLayer"] as? Int, layer == statusLevel,
                  let bounds = info["kCGWindowBounds"] as? [String: CGFloat],
                  let x = bounds["X"], let width = bounds["Width"],
                  let y = bounds["Y"], let height = bounds["Height"],
                  abs(y - menuBarY) < 2, height <= menuBarWindowMaxHeight
            else { continue }

            let drawn = (info["kCGWindowIsOnscreen"] as? Bool) ?? false

            if ownDrawn == nil, let own = ownFrame,
               abs(x - own.minX) < 2, abs(width - own.width) < 2 {
                ownDrawn = drawn
                continue
            }
            // An item the window server is not drawing is not holding any
            // space, whatever its row says its width is.
            guard drawn else { continue }
            anyDrawn = true
            // Only the part inside the region counts; an item straddling the
            // notch edge is not taking space we could have used.
            let overlap = min(x + width, rightLimit) - max(x, leftLimit)
            if overlap > 0 { occupied += overlap }
        }

        return Fit(
            available: rightLimit - leftLimit - occupied
                - chrome(of: window, length: item.length) - safetyMargin,
            occupied: occupied,
            // With nothing else drawn there is no menu bar on screen to be
            // absent from, so our own absence is not evidence of anything.
            isDrawn: claimUndrawn ? false : (anyDrawn ? ownDrawn : nil)
        )
    }

    /// The window is a little wider than the length asked for. Measuring the
    /// difference rather than assuming it keeps this correct if the padding
    /// ever changes, but a stale frame — the window resizes a beat after
    /// `length` is set — would otherwise produce a nonsense number, so an
    /// implausible difference falls back to the value observed on macOS 26.
    private static func chrome(of window: NSWindow?, length: CGFloat) -> CGFloat {
        guard let window else { return assumedChrome }
        let measured = window.frame.width - length
        guard length > 0, (0...40).contains(measured) else { return assumedChrome }
        return measured
    }
}
