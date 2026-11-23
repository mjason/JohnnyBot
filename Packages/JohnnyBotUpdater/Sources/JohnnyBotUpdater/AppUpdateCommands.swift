#if os(macOS)
import Combine
import Sparkle
import SwiftUI

@MainActor
public struct AppUpdateCommands: Commands {
    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: controller.updater)
        }
    }
}

private struct CheckForUpdatesButton: View {
    @MainActor
    private final class Availability: ObservableObject {
        @Published private(set) var canCheckForUpdates: Bool

        init(_ updater: SPUUpdater) {
            canCheckForUpdates = updater.canCheckForUpdates
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        }
    }

    let updater: SPUUpdater
    @StateObject private var availability: Availability

    init(updater: SPUUpdater) {
        self.updater = updater
        _availability = StateObject(wrappedValue: Availability(updater))
    }

    var body: some View {
        Button("检查更新…", action: updater.checkForUpdates)
            .disabled(!availability.canCheckForUpdates)
    }
}
#endif
