import SwiftUI
import UIKit

@Observable
final class DrawerManager {
    var isOpen = false

    func open() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { isOpen = true }
    }
    func close() { withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { isOpen = false } }
    func toggle() { isOpen ? close() : open() }
}
