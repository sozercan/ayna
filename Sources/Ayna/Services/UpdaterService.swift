#if os(macOS)
    import Foundation
    import Sparkle

    @available(macOS 14.0, *)
    @MainActor
    @Observable
    final class UpdaterService {
        private let updaterController: SPUStandardUpdaterController

        var canCheckForUpdates: Bool {
            updaterController.updater.canCheckForUpdates
        }

        init() {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )

            DiagnosticsLogger.log(
                .updater,
                level: .info,
                message: "UpdaterService initialized"
            )
        }

        func checkForUpdates() {
            DiagnosticsLogger.log(
                .updater,
                level: .info,
                message: "Manually checking for updates"
            )
            updaterController.checkForUpdates(nil)
        }
    }
#endif
