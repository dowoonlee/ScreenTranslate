import AppKit
import Combine
import Sparkle

/// Starts only after a user clicks the update button. No startup popup or telemetry.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheck = true
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?

    func checkForUpdates() {
        guard canCheck else { return }
        if controller == nil {
            let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
            controller = updater
            observation = updater.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] value in self?.canCheck = value }
            updater.startUpdater()
        }
        controller?.checkForUpdates(nil)
    }
}
