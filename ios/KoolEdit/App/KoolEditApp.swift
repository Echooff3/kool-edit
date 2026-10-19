import SwiftUI

@main
struct KoolEditApp: App {
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                // Like the macOS app, the look is the point: no dark mode.
                .preferredColorScheme(.light)
                .tint(Theme.navy)
                .onOpenURL { library.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.importInbox() }
        }
    }
}
