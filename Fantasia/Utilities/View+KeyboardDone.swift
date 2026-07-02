import SwiftUI

private struct KeyboardDoneModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(content: {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            }
        })
    }
}

extension View {
    func keyboardDoneButton() -> some View {
        modifier(KeyboardDoneModifier())
    }
}
