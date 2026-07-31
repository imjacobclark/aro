import AppKit
import SwiftUI

/// Restores the standard AppKit title bar gestures — drag to move, double-click
/// to zoom/minimise — that a `.hiddenTitleBar` window otherwise loses.
///
/// With `.hiddenTitleBar` the window gains `.fullSizeContentView`, so SwiftUI's
/// content view stretches under the title bar strip. Whatever sits up there —
/// the sidebar's `List`, a content pane's `ScrollView` — hit-tests first and
/// swallows the click, so the window frame never sees the double-click that
/// would have zoomed it. This overlay claims that strip back.
///
/// Layer it over the whole window (`.ignoresSafeArea()`); it only hit-tests
/// inside the title bar band, so content below stays fully interactive. The
/// traffic light buttons live in the window's title bar container view, which
/// is ordered above the content view, so they keep working too.
struct TitleBarInteractionOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarInteractionView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarInteractionView: NSView {
    /// Claims clicks only inside the title bar strip, measured against the
    /// window's own layout rather than a hardcoded height so it stays correct
    /// for whatever title bar size the window actually has.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window,
              let pointInWindow = superview?.convert(point, to: nil),
              window.styleMask.contains(.fullSizeContentView),
              !window.styleMask.contains(.fullScreen)
        else { return nil }
        return pointInWindow.y >= window.contentLayoutRect.maxY ? self : nil
    }

    /// The title bar is draggable even when the window isn't key, so a first
    /// click here should act rather than merely activate.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// Mirrors AppleAction on double click from System Settings › Desktop &
    /// Dock, which is what a real title bar honours. Absent that key, macOS
    /// zooms.
    private func performDoubleClickAction(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }
}
