import AppKit
import SwiftUI

/// The window the detail panel lives in.
///
/// Not an `NSPopover`, which is one opaque-feeling sheet with an arrow. Control
/// Center and the Wi-Fi menu are borderless and clear, with glass only where
/// there is content, so anything behind shows through between the modules.
/// Non-activating, so opening it does not take focus from the app in use.
final class GlassPanel: NSPanel {
    /// Called for Esc, once nothing inside the panel has claimed it.
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        // Glass text is white in Control Center whatever the system setting.
        appearance = NSAppearance(named: .darkAqua)
    }

    // Borderless windows refuse key status by default, which would leave the
    // charts' arrow keys and Esc with nowhere to go.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Glass from macOS 26, and the closest material before it.
///
/// The clear variant, as Control Center uses: `regular` greys what is behind
/// it, which reads as a background colour rather than as glass. Clear alone
/// leaves sharp text behind ours, so the thinnest blur sits underneath it, the
/// way Control Center blurs the desktop behind its modules. `blur` is how much
/// of it: small modules can spare some, and a list of rows needs all of it.
extension View {
    @ViewBuilder
    func glassModule<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false,
                              blur: Double = 0.85) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.clear.tint(tint).interactive(interactive), in: shape)
                .background { shape.fill(.ultraThinMaterial).opacity(blur) }
        } else {
            background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.3), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.15), lineWidth: 1))
        }
    }
}

/// Lets sibling modules share one sampling pass. Spacing zero keeps them
/// separate shapes rather than letting neighbours melt together.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}
