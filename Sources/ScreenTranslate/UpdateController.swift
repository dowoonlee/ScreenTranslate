import AppKit
import Combine
import Sparkle

/// A silent launch check; only a newer signed release presents update UI.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheck = true
    private var controller: SPUStandardUpdaterController?
    private var observation: AnyCancellable?
    private var checkedAtLaunch = false

    func checkAtLaunch() {
        guard !checkedAtLaunch else { return }
        checkedAtLaunch = true
        startIfNeeded().updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        guard canCheck else { return }
        startIfNeeded().checkForUpdates(nil)
    }

    private func startIfNeeded() -> SPUStandardUpdaterController {
        if let controller { return controller }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller = updater
        observation = updater.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheck = value }
        updater.startUpdater()
        return updater
    }
}
