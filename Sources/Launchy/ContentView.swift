import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home = "Accueil"
    case mods = "Mods"
    case skins = "Skins"
    case account = "Compte"
    case settings = "Réglages"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .mods: "shippingbox"
        case .skins: "person.crop.square"
        case .account: "person.circle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: AppSection? = .home

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selection ?? .home {
            case .home: HomeView()
            case .mods: PlaceholderView(title: "Mods", systemImage: "shippingbox")
            case .skins: PlaceholderView(title: "Skins", systemImage: "person.crop.square")
            case .account: AccountView()
            case .settings: PlaceholderView(title: "Réglages", systemImage: "gearshape")
            }
        }
    }
}

struct PlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text("Bientôt disponible"))
    }
}
