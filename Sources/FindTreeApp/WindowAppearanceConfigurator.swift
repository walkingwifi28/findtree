import AppKit
import SwiftUI

struct WindowAppearanceConfigurator: NSViewRepresentable {
    let visualStyleRawValue: String
    let colorScheme: ColorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyConfiguration(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyConfiguration(to: nsView, coordinator: context.coordinator)
    }

    private func applyConfiguration(to view: NSView, coordinator: Coordinator) {
        let backgroundColor = windowBackgroundColor

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            coordinator.attach(to: window, backgroundColor: backgroundColor)
        }
    }

    private var windowBackgroundColor: NSColor {
        switch colorScheme {
        case .dark:
            return NSColor(
                srgbRed: 0.16,
                green: 0.16,
                blue: 0.175,
                alpha: 1
            )
        default:
            return NSColor(
                srgbRed: 224.0 / 255.0,
                green: 224.0 / 255.0,
                blue: 224.0 / 255.0,
                alpha: 1
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var backgroundColor = NSColor.windowBackgroundColor

        func attach(to window: NSWindow, backgroundColor: NSColor) {
            self.backgroundColor = backgroundColor

            if self.window !== window {
                stopObservingWindow()
                self.window = window
                startObserving(window)
            }

            applyAppearance()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private func startObserving(_ window: NSWindow) {
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowActivationStateDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowActivationStateDidChange(_:)),
                name: NSWindow.didBecomeMainNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowActivationStateDidChange(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowActivationStateDidChange(_:)),
                name: NSWindow.didResignMainNotification,
                object: window
            )
        }

        private func stopObservingWindow() {
            guard let window else { return }
            NotificationCenter.default.removeObserver(self, name: nil, object: window)
        }

        @objc
        private func windowActivationStateDidChange(_ notification: Notification) {
            guard let notificationWindow = notification.object as? NSWindow,
                  notificationWindow === window
            else { return }

            // AppKit redraws the titlebar when key/main state changes. Reapply our
            // transparent titlebar configuration after that redraw so the titlebar
            // keeps matching the content background while focus moves between apps.
            applyAppearance()
        }

        private func applyAppearance() {
            guard let window else { return }

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = backgroundColor
            window.contentView?.needsDisplay = true
        }
    }
}
