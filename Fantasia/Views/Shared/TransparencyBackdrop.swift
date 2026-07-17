// TransparencyBackdrop.swift
// Neutral checkerboard used behind alpha-bearing image/video previews.

import SwiftUI

struct TransparencyBackdrop: View {
    var cellSize: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.07)))
                }
            }
        }
        .background(Color.primary.opacity(0.025))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
