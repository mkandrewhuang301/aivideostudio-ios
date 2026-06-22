// SplashView.swift
// Fantasia

import SwiftUI

struct SplashView: View {
    private let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.10, green: 0.10, blue: 0.18),
            Color(red: 0.07, green: 0.07, blue: 0.16),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 32) { // xl (32pt)
                Text("Fantasia")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)

                ProgressView()
                    .tint(accent)
                    .scaleEffect(1.2)
            }
        }
    }
}

#Preview {
    SplashView()
}
