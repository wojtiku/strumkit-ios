import SwiftUI

@main
struct StrumKitApp: App {
    var body: some Scene {
        WindowGroup {
            TunerView()
                .preferredColorScheme(.dark)
        }
    }
}
