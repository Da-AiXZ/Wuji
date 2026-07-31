import SwiftUI

@main
struct WujiApp: App {
    init() {
        S3ProbeRunner.startIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
