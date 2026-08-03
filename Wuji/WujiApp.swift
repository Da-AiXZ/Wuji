import SwiftUI

@main
struct WujiApp: App {
    @StateObject private var stageAViewModel = StageAViewModel()

    init() {
        S3ProbeRunner.startIfRequested()
        S4ProbeRunner.startIfRequested()
        StageBProbeRunner.startIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: stageAViewModel)
        }
    }
}
