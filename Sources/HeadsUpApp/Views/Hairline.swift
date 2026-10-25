import SwiftUI

/// A horizontal separator line: one device pixel, or a full point with Increase Contrast.
struct Hairline: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HUDStyle.Colors.line
            .frame(height: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            .accessibilityHidden(true)
    }
}
