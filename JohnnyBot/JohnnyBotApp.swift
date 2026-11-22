import SwiftUI

@main
struct JohnnyBotApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
#if os(macOS)
        .defaultSize(width: 1020, height: 680)
#endif
    }
}
