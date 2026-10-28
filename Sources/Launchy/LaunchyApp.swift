import AppKit
import SwiftUI

@main
struct LaunchyApp: App {
    @State private var accountStore = AccountStore()

    init() {
        // Un binaire lancé par `swift run` n'est pas une app .app : il faut
        // lui demander explicitement de s'afficher et de passer au premier plan.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(accountStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}
