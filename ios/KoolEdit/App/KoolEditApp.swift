import SwiftUI

/// Every take on the device: one Library shared by the iPhone screen and
/// the CarPlay screen, so the car sees what the phone has.
extension Library {
    static let shared = Library()
}

@main
struct KoolEditApp: App {
    @State private var library = Library.shared
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
