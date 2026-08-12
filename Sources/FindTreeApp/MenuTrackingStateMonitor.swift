import AppKit
import SwiftUI

/// Keeps the neumorphic Options surface in sync with the native SwiftUI Menu.
///
/// The Options menu is identified by its own contents (the `Appearance` picker)
/// instead of mouse-down delivery or geometry. SwiftUI's `Menu` runs AppKit's
/// nested menu-tracking loop, and mouse events around repeated openings are not
/// a stable presentation-state signal. NSMenu begin/end tracking notifications
/// are stable across every opening.
struct MenuTrackingStateMonitor: NSViewRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.startMonitoring()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isPresented = $isPresented
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator: NSObject {
        var isPresented: Binding<Bool>

        private var trackedMenu: NSMenu?
        private var isMonitoring = false

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
            super.init()
        }

        func startMonitoring() {
            guard !isMonitoring else { return }
            isMonitoring = true

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidBeginTracking(_:)),
                name: NSMenu.didBeginTrackingNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(menuDidEndTracking(_:)),
                name: NSMenu.didEndTrackingNotification,
                object: nil
            )
        }

        func stopMonitoring() {
            guard isMonitoring else { return }
            NotificationCenter.default.removeObserver(self)
            isMonitoring = false
            trackedMenu = nil
        }

        @objc private func menuDidBeginTracking(_ notification: Notification) {
            guard trackedMenu == nil,
                  let menu = notification.object as? NSMenu,
                  isOptionsMenu(menu) else {
                return
            }

            trackedMenu = menu
            setPresented(true)
        }

        @objc private func menuDidEndTracking(_ notification: Notification) {
            guard let menu = notification.object as? NSMenu,
                  menu === trackedMenu else {
                return
            }

            trackedMenu = nil
            setPresented(false)
        }

        private func isOptionsMenu(_ menu: NSMenu) -> Bool {
            menuContainsTitle("Appearance", in: menu)
        }

        private func menuContainsTitle(_ title: String, in menu: NSMenu) -> Bool {
            for item in menu.items {
                if item.title == title {
                    return true
                }
                if let submenu = item.submenu,
                   menuContainsTitle(title, in: submenu) {
                    return true
                }
            }
            return false
        }

        private func setPresented(_ presented: Bool) {
            guard isPresented.wrappedValue != presented else { return }
            isPresented.wrappedValue = presented
        }

        deinit {
            stopMonitoring()
        }
    }
}
