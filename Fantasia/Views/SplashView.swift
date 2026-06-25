// SplashView.swift
// Fantasia

import SwiftUI

struct SplashView: View {
    private let background = Color(red: 0.085, green: 0.085, blue: 0.17)

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text("Fantasia")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    SplashView()
}
