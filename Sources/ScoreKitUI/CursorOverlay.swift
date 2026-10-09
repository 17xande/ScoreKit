#if canImport(SwiftUI)
import ScoreKit
import SwiftUI

/// The playback cursor band, on a layer of its own above the systems, so moving it at 60 fps
/// never redraws the notes. It fills its parent and positions a single rectangle.
///
/// `origin` is the layout point (staff spaces) at the parent's top-left; zero for a whole
/// page, the row's or region's origin otherwise.
public struct CursorOverlay: View {
    public var spot: CursorSpot?
    public var scale: Double
    public var color: Color
    public var origin: CGPoint

    public init(spot: CursorSpot?, scale: Double, color: Color = Color.accentColor.opacity(0.3), origin: CGPoint = .zero) {
        self.spot = spot; self.scale = scale; self.color = color; self.origin = origin
    }

    public var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                if let spot {
                    let r = spot.bandRect
                    Rectangle()
                        .fill(color)
                        .frame(width: r.width * scale, height: r.height * scale)
                        .offset(x: (r.minX - origin.x) * scale, y: (r.minY - origin.y) * scale)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A cursor resolved from a `CursorSource` against a layout, ticking on the display clock only
/// when the source is animated (see `CursorSource` for the threading and pausing rules). With
/// `systemIndex` set, the band shows only when the cursor is on that system (one overlay per
/// page row).
public struct GlidingCursorOverlay: View {
    public var layout: PreparedLayout
    public var source: CursorSource
    public var scale: Double
    public var color: Color
    public var origin: CGPoint
    public var systemIndex: Int?

    public init(layout: PreparedLayout, source: CursorSource, scale: Double,
                color: Color = Color.accentColor.opacity(0.3), origin: CGPoint = .zero, systemIndex: Int? = nil) {
        self.layout = layout; self.source = source; self.scale = scale; self.color = color
        self.origin = origin; self.systemIndex = systemIndex
    }

    public var body: some View {
        TimelineView(.animation(paused: !source.isAnimated)) { tl in
            let spot = source.spot(in: layout.layout, at: tl.date)
            CursorOverlay(spot: spot.flatMap { systemIndex == nil || $0.systemIndex == systemIndex ? $0 : nil },
                          scale: scale, color: color, origin: origin)
        }
    }
}
#endif
