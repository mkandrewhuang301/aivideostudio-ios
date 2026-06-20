// ContentView.swift
// Fantasia

import SwiftUI

@Observable
final class ContentViewModel {
    var connectionStatus: String = "Checking..."
    var isConnected: Bool = false

    func checkHealth() async {
        do {
            let response = try await APIClient.shared.healthCheck()
            isConnected = response.status == "ok"
            connectionStatus = isConnected ? "Backend connected" : "Backend degraded"
        } catch {
            isConnected = false
            connectionStatus = "Backend unreachable"
        }
    }
}

struct ContentView: View {
    @State private var viewModel = ContentViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Fantasia")
                    .font(.largeTitle.bold())

                HStack {
                    Image(systemName: viewModel.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(viewModel.isConnected ? .green : .red)
                    Text(viewModel.connectionStatus)
                        .foregroundStyle(.secondary)
                }

                Text(AppConfig.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .navigationTitle("Fantasia Dev")
        }
        .task {
            await viewModel.checkHealth()
        }
    }
}

#Preview {
    ContentView()
}
