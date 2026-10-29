import AppKit
import HeadsUpCore
import SwiftUI

/// The HUD's container: a header area, an optional body and a footer area, on the HUD
/// material under the `--hud` tint, with rounded corners and an edge: a hairline border in light mode; in dark mode a dark
/// outline with a faint light rim just inside it, as native dark windows have, so the HUD stands
/// out from dark windows and a dark desktop behind it.
///
/// The panel that hosts this view must be clear and non-opaque, with `hasShadow` on:
/// macOS then draws the window shadow around the rounded material.
struct HUDFrameView<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity)
                .frame(height: HUDMetrics.headerHeight)
            content
            footer
                .frame(maxWidth: .infinity)
                .frame(height: HUDMetrics.footerHeight)
        }
        // The blur, with the `--hud` tint over it; one mask rounds both. The edge draws above.
        .background {
            ZStack {
                HUDMaterial()
                HUDStyle.Colors.hudTint(colorScheme, contrast: contrast)
            }
        }
        .clipShape(shape)
        .overlay(edge)
    }

    /// Both strokes are drawn inside the shape: the window is exactly the HUD's size. Each is one
    /// device pixel, or 1 pt with Increase Contrast.
    @ViewBuilder private var edge: some View {
        let width = HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale)
        if colorScheme == .dark {
            ZStack {
                shape.strokeBorder(HUDStyle.Colors.edgeOuter(contrast), lineWidth: width)
                shape.inset(by: width).strokeBorder(HUDStyle.Colors.edgeInner(contrast), lineWidth: width)
            }
        } else {
            shape.strokeBorder(HUDStyle.Colors.line, lineWidth: width)
        }
    }

    // Circular corners, to match the material's mask exactly.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDMetrics.cornerRadius, style: .circular)
    }
}

extension HUDFrameView where Header == EmptyView, Content == EmptyView, Footer == EmptyView {
    /// The empty HUD: header and footer areas with nothing in them.
    init() {
        self.init(header: { EmptyView() }, content: { EmptyView() }, footer: { EmptyView() })
    }
}

/// The HUD's background: the popover material, blurring what is behind the window. It is
/// light in light appearance and dark in dark, as Spotlight is; the HUD window material
/// (`.hudWindow`) stays dark-tinted in light appearance. It follows the app's appearance,
/// which Settings → General → Appearance sets (AppDelegate).
///
/// With Reduce Transparency on, macOS makes this material opaque by itself.
private struct HUDMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The HUD panel never becomes the main window, so the material must not follow
        // the window's active state, or it would always look inactive.
        view.state = .active
        // The mask rounds the material, and so the window shadow, which follows its shape.
        view.maskImage = Self.roundedMask(radius: HUDMetrics.cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A small rounded rectangle that stretches in the middle and keeps its corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

#if DEBUG
    struct HUDFrameViewPreviews: PreviewProvider {
        static var previews: some View {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HUDFrameView()
                    .frame(width: HUDLayout.maxWidth)
                    .padding(40)
                    .preferredColorScheme(scheme)
                    .previewDisplayName(scheme == .light ? "Light" : "Dark")
            }
        }
    }
#endif
