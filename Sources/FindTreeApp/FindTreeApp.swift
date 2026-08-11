import SwiftUI

@main
struct FindTreeDesktopApp: App {
    var body: some Scene {
        WindowGroup("FindTree") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
