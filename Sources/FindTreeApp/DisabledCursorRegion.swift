import AppKit
import SwiftUI

/// Shows the macOS unavailable cursor over a disabled SwiftUI control.
/// A tracking area is used instead of cursor rects because NSHostingView may
/// refresh its own cursor rects after child views and override them.
struct DisabledCursorRegion: NSViewRepresentable {
    let isDisabled: Bool

    func makeNSView(context: Context) -> DisabledCursorView {
        let view = DisabledCursorView(frame: .zero)
        view.setDisabled(isDisabled)
        return view
    }

    func updateNSView(_ nsView: DisabledCursorView, context: Context) {
        nsView.setDisabled(isDisabled)
    }
}

@MainActor
final class DisabledCursorView: NSView {
    private var isDisabled = false
    private var trackingAreaRef: NSTrackingArea?
    private var isPointerInside = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .cursorUpdate,
                .activeAlways,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    func setDisabled(_ disabled: Bool) {
        guard isDisabled != disabled else { return }
        isDisabled = disabled

        guard isPointerInside else { return }
        applyCursor()
    }

    private func applyCursor() {
        if isDisabled {
            NSCursor.operationNotAllowed.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
