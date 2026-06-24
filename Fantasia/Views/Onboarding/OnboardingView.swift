// OnboardingView.swift — placeholder stub. Full implementation in Plan 07.
import SwiftUI
struct OnboardingView: View {
    var onComplete: () -> Void
    var body: some View { Color.black.ignoresSafeArea().onTapGesture { onComplete() } }
}
