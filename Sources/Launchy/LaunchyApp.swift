import SwiftUI

@main
struct LaunchyApp: App {
    @State private var accountStore = AccountStore()

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
