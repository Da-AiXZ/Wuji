import SwiftUI

struct DeepSeekSettingsView: View {
    @ObservedObject var viewModel: StageAViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("DeepSeek") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("模型设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let saved = viewModel.saveConfiguration(
                            baseURL: baseURL,
                            model: model,
                            apiKey: apiKey
                        )
                        apiKey = ""
                        if saved { dismiss() }
                    }
                    .disabled(baseURL.isEmpty || model.isEmpty || apiKey.isEmpty)
                }
            }
            .onAppear {
                guard let configuration = viewModel.existingConfiguration() else { return }
                baseURL = configuration.baseURL
                model = configuration.model
            }
        }
    }
}
