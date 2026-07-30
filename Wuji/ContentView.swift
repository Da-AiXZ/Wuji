import SwiftUI

struct ContentView: View {
    private let taskState = WujiTaskState.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("无极")
                .font(.largeTitle)
                .bold()

            Spacer()

            HStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.title2)
                    .foregroundColor(.secondary)

                Text(taskState.statusText)
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer()
        }
        .padding(24)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

