import SwiftUI

/// Shared metrics for the compact AppKit menu surface. Keeping these values in
/// one place prevents telemetry and action rows from drifting apart visually.
enum StasisMenuMetrics {
    static let width: CGFloat = 300
    static let horizontalPadding: CGFloat = 14
    static let compactRowPadding: CGFloat = 3
    static let regularRowPadding: CGFloat = 6
    static let sectionSpacing: CGFloat = 6
}

extension View {
    func stasisMenuRowPadding(
        vertical: CGFloat = StasisMenuMetrics.compactRowPadding
    ) -> some View {
        padding(.horizontal, StasisMenuMetrics.horizontalPadding)
            .padding(.vertical, vertical)
    }
}
