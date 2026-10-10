#if canImport(SwiftUI)
import ScoreKit
import SwiftUI

public typealias StaffRef = LayoutOptions.StaffRef

/// How a `ScoreView` lays out and shows a score.
public struct ScoreViewOptions: Equatable, Sendable {
    public enum Mode: Sendable, Hashable {
        /// Systems stacked vertically in a scroll view.
        case page
        /// One long system, scrolled sideways to keep the cursor in view.
        case line
    }

    public var mode: Mode
    public var zoom: Double
    public var showFingering: Bool
    /// Staves to show; nil is all.
    public var staves: [StaffRef]?
    /// Ink colour; nil takes the environment's primary colour (light and dark aware).
    public var ink: Color?
    /// Points per staff space at zoom 1.
    public var basePointsPerSpace: Double
    /// Where the cursor sits across the viewport in line mode.
    public var cursorAnchor: Double
    public var cursorColor: Color
    /// Line mode: when set, the current clef, key and time stay pinned at the left edge once the line is
    /// scrolled, on this background (the sheet's paper colour: the notes scroll under it). Nil: no header.
    public var stickyBackground: Color?

    public init(mode: Mode = .page, zoom: Double = 1, showFingering: Bool = false, staves: [StaffRef]? = nil,
                ink: Color? = nil, basePointsPerSpace: Double = 8, cursorAnchor: Double = 0.2,
                cursorColor: Color = Color.accentColor.opacity(0.3), stickyBackground: Color? = nil) {
        self.mode = mode; self.zoom = zoom; self.showFingering = showFingering; self.staves = staves
        self.ink = ink; self.basePointsPerSpace = basePointsPerSpace; self.cursorAnchor = cursorAnchor
        self.cursorColor = cursorColor
        self.stickyBackground = stickyBackground
    }

    var scale: Double { max(0.5, basePointsPerSpace * zoom) }
}

/// Caches the layout; it is recomputed only when the score, mode, zoom (page mode), fingering
/// or staves change, or the width changes by more than 24 points (or shrinks below the laid
/// width, so the layout never overflows). That is a hysteresis rule, not a timer.
final class LayoutCache {
    private struct Key: Equatable {
        var mode: ScoreViewOptions.Mode
        /// Only page layouts depend on the scale (through the width in staff spaces).
        var scale: Double?
        var fingering: Bool
        var staves: [StaffRef]?
        var scoreID: AnyHashable?
    }

    private var score: Score?
    private var key: Key?
    private var laidWidth = 0.0
    private var cached: PreparedLayout?

    func prepared(score: Score, scoreID: AnyHashable?, options: ScoreViewOptions, width: Double) -> PreparedLayout {
        let k = Key(mode: options.mode, scale: options.mode == .page ? options.scale : nil,
                    fingering: options.showFingering, staves: options.staves, scoreID: scoreID)
        // With an id the score is trusted to be unchanged while the id is; without one it is
        // compared (cheap when the arrays are the same storage).
        if let cached, key == k, scoreID != nil || self.score == score {
            if options.mode == .line { return cached }
            if width >= laidWidth - 0.5, width - laidWidth <= 24 { return cached }
        }
        let w: LayoutOptions.Width = options.mode == .line ? .singleLine : .fixed(max(10, width / options.scale))
        let layout = Engraver.layout(score, options: LayoutOptions(width: w, showFingering: options.showFingering, staves: options.staves))
        let p = PreparedLayout(layout: layout)
        self.score = scoreID == nil ? score : nil
        key = k; laidWidth = width; cached = p
        return p
    }
}

/// A score: systems drawn with Bravura, an optional cursor and per-note marks, tap to seek.
///
/// The background is transparent (the app decides). `marks` colour individual notes (current,
/// ok, bad...); `measureTints` tint whole measures behind the notes (results heatmap).
///
/// The layout is private and reflows with width, zoom and mode, so the cursor is given in
/// layout-independent form (`CursorSource`) and resolved internally. `onLayout` hands the
/// caller each new `ScoreLayout` (for example to read `hitTest`, measure positions or
/// `ScoreView.lineHeight`).
///
/// Taps: `onTap` gets the note hit and `onTapMeasure` the measure; when both are set both fire
/// for one tap. In line mode a tap also resumes following the cursor.
public struct ScoreView: View {
    public var score: Score
    /// Identifies `score`: when given, the layout is reused while it is unchanged, without
    /// comparing the score. Pass something that changes whenever the score does (a song id).
    public var scoreID: AnyHashable?
    public var options: ScoreViewOptions
    public var marks: [NoteID: Color]
    public var cursor: CursorSource
    public var measureTints: [Int: Color]
    public var onTap: ((HitResult) -> Void)?
    public var onTapMeasure: ((Int) -> Void)?
    /// Called (on the main actor) whenever a new layout is computed, including the first.
    public var onLayout: ((ScoreLayout) -> Void)?
    /// Change this on each seek: line mode resumes following the cursor after a manual scroll.
    public var seekToken: Int

    @State private var cache = LayoutCache()
    @State private var manualOffset: Double?

    public init(score: Score, scoreID: AnyHashable? = nil, options: ScoreViewOptions = ScoreViewOptions(),
                marks: [NoteID: Color] = [:], cursor: CursorSource = .hidden,
                measureTints: [Int: Color] = [:], seekToken: Int = 0,
                onTap: ((HitResult) -> Void)? = nil, onTapMeasure: ((Int) -> Void)? = nil,
                onLayout: ((ScoreLayout) -> Void)? = nil) {
        self.score = score; self.scoreID = scoreID; self.options = options; self.marks = marks
        self.cursor = cursor; self.measureTints = measureTints; self.seekToken = seekToken
        self.onTap = onTap; self.onTapMeasure = onTapMeasure; self.onLayout = onLayout
    }

    /// The height of the line view for a layout, in points: use it to size the view, which
    /// otherwise takes all the height it is offered.
    public static func lineHeight(for layout: ScoreLayout, options: ScoreViewOptions) -> Double {
        PreparedLayout(layout: layout).lineRegion().height * options.scale
    }

    public var body: some View {
        GeometryReader { geo in
            if geo.size.width > 1 {
                let prepared = cache.prepared(score: score, scoreID: scoreID, options: options, width: geo.size.width)
                Group {
                    switch options.mode {
                    case .page:
                        PageContent(prepared: prepared, options: options, marks: marks, measureTints: measureTints,
                                    source: cursor, onTap: handleTap(prepared))
                    case .line:
                        LineContent(prepared: prepared, options: options, marks: marks, measureTints: measureTints,
                                    source: cursor, viewport: geo.size, manualOffset: $manualOffset,
                                    onTap: handleTap(prepared))
                    }
                }
                .onChange(of: ObjectIdentifier(prepared), initial: true) { _, _ in
                    manualOffset = nil
                    onLayout?(prepared.layout)
                }
            } else {
                Color.clear
            }
        }
        .onChange(of: seekToken) { _, _ in manualOffset = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityLabel: String {
        let n = score.parts.map(\.measures.count).max() ?? 0
        let title = score.title.map { "Score, \($0)" } ?? "Score"
        return "\(title), \(n) \(n == 1 ? "measure" : "measures")"
    }

    /// Takes a point in layout-origin content points and calls the callbacks.
    private func handleTap(_ prepared: PreparedLayout) -> (CGPoint) -> Void {
        let scale = options.scale
        let onTap = onTap, onTapMeasure = onTapMeasure
        return { p in
            let q = CGPoint(x: p.x / scale, y: p.y / scale)
            if let onTap, let hit = prepared.layout.hitTest(q) { onTap(hit) }
            if let onTapMeasure, let m = prepared.layout.hitTestMeasure(q) { onTapMeasure(m) }
        }
    }
}

// MARK: Page

private struct PageContent: View {
    var prepared: PreparedLayout
    var options: ScoreViewOptions
    var marks: [NoteID: Color]
    var measureTints: [Int: Color]
    var source: CursorSource
    var onTap: (CGPoint) -> Void

    private struct FollowKey: Equatable {
        var system: Int?
        var layout: ObjectIdentifier
    }

    var body: some View {
        let scale = options.scale
        let layout = prepared.layout
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Each row carries its own cursor layer and tap gesture, positioned from its
                // own origin, so estimated lazy heights cannot misplace either.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.systems.indices, id: \.self) { i in
                        let row = prepared.pageRow(i)
                        ScoreCanvas(layout: prepared, systemIndex: i, scale: scale, ink: options.ink ?? .primary,
                                    noteColors: marks, measureTints: measureTints, region: row)
                            .equatable()
                            .overlay {
                                GlidingCursorOverlay(layout: prepared, source: source, scale: scale,
                                                     color: options.cursorColor, origin: row.origin, systemIndex: i)
                            }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in
                                onTap(CGPoint(x: v.location.x + row.minX * scale, y: v.location.y + row.minY * scale))
                            })
                            .id(i)
                    }
                }
                .frame(width: layout.size.width * scale, alignment: .topLeading)
            }
            .background {
                // Follows the cursor's system, on first appearance and after a reflow too.
                TimelineView(.animation(paused: !source.isAnimated)) { tl in
                    let key = FollowKey(system: source.spot(in: layout, at: tl.date)?.systemIndex, layout: ObjectIdentifier(prepared))
                    Color.clear.onChange(of: key, initial: true) { _, k in
                        guard let s = k.system else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(s, anchor: .center) }
                    }
                }
            }
        }
    }
}

// MARK: Line

private struct LineTiles: View, Equatable {
    var prepared: PreparedLayout
    var options: ScoreViewOptions
    var marks: [NoteID: Color]
    var measureTints: [Int: Color]
    var first: Int
    var last: Int

    nonisolated static func == (a: LineTiles, b: LineTiles) -> Bool {
        a.prepared === b.prepared && a.options == b.options && a.marks == b.marks
            && a.measureTints == b.measureTints && a.first == b.first && a.last == b.last
    }

    var body: some View {
        let scale = options.scale
        let region = prepared.lineRegion()
        let tileSp = LineContent.tilePoints / scale
        ZStack(alignment: .topLeading) {
            ForEach(first <= last ? Array(first...last) : [], id: \.self) { t in
                let x0 = Double(t) * tileSp
                let w = min(tileSp, prepared.layout.size.width - x0)
                if w > 0 {
                    ScoreCanvas(layout: prepared, systemIndex: 0, scale: scale, ink: options.ink ?? .primary,
                                noteColors: marks, measureTints: measureTints,
                                region: CGRect(x: x0, y: region.minY, width: w, height: region.height))
                        .equatable()
                        .offset(x: x0 * scale)
                }
            }
        }
    }
}

/// The sticky header of a scrolled line: an opaque background and the clef, key and time of the staves,
/// drawn by `ScoreCanvas` from the header layout (`ScoreLayout.stickyHeader`). Equatable on the
/// contexts, so it only redraws when a clef, key or time changes. Not checked on device yet.
private struct StickyHeaderView: View, Equatable {
    var prepared: PreparedLayout
    var contexts: [StaffContext]
    var scale: Double
    var region: CGRect
    var ink: Color
    var background: Color

    nonisolated static func == (a: StickyHeaderView, b: StickyHeaderView) -> Bool {
        a.prepared === b.prepared && a.contexts == b.contexts && a.scale == b.scale && a.region == b.region
            && a.ink == b.ink && a.background == b.background
    }

    var body: some View {
        if let h = prepared.layout.stickyHeader(for: contexts) {
            ScoreCanvas(layout: PreparedLayout(layout: h.layout), systemIndex: 0, scale: scale, ink: ink,
                        region: CGRect(x: 0, y: region.minY, width: h.width, height: region.height))
                .background(background)
                // Taps on the header do nothing: they must not seek to the notes under it.
                .contentShape(Rectangle())
                .onTapGesture {}
        }
    }
}

private struct LineContent: View {
    var prepared: PreparedLayout
    var options: ScoreViewOptions
    var marks: [NoteID: Color]
    var measureTints: [Int: Color]
    var source: CursorSource
    var viewport: CGSize
    @Binding var manualOffset: Double?
    var onTap: (CGPoint) -> Void

    @Environment(\.displayScale) private var displayScale
    /// The offset of a cursor that is not animated (it eases between jumps).
    @State private var shown = 0.0
    @State private var dragBase: Double?
    /// Tile width in points: keeps each canvas small, and only tiles near the viewport exist.
    static let tilePoints = 1024.0

    private var scale: Double { options.scale }
    private var contentWidth: Double { prepared.layout.size.width * scale }
    private var maxOffset: Double { max(0, contentWidth - viewport.width) }

    private func follow(_ spot: CursorSpot?) -> Double {
        guard let spot else { return 0 }
        // With the sticky header the cursor sits right of it (its widest form plus 2 staff spaces).
        var anchor = options.cursorAnchor
        if options.stickyBackground != nil { anchor = max(anchor, (prepared.stickyHeaderWidth + 2) * scale / viewport.width) }
        return prepared.layout.scrollOffset(for: spot, viewportWidth: viewport.width / scale, anchor: min(anchor, 0.6)) * scale
    }

    private func clamped(_ o: Double) -> Double { min(max(0, o), maxOffset) }

    private func target(_ spot: CursorSpot?) -> Double { clamped(manualOffset ?? follow(spot)) }

    /// Offsets snap to device pixels, so tile seams never land between pixels.
    private func snapped(_ o: Double) -> Double { (o * displayScale).rounded() / displayScale }

    var body: some View {
        let region = prepared.lineRegion()
        let height = region.height * scale
        let animated = source.isAnimated
        let staticSpot = animated ? nil : source.spot(in: prepared.layout, at: Date())
        let staticTarget = target(staticSpot)
        TimelineView(.animation(paused: !animated)) { tl in
            let spot = animated ? source.spot(in: prepared.layout, at: tl.date) : staticSpot
            let off = snapped(animated ? target(spot) : clamped(manualOffset ?? shown))
            let tileFirst = max(0, Int(((off - viewport.width) / Self.tilePoints).rounded(.down)))
            let tileLast = min(Int((contentWidth / Self.tilePoints).rounded(.down)),
                               Int(((off + 2 * viewport.width) / Self.tilePoints).rounded(.down)))
            ZStack(alignment: .topLeading) {
                LineTiles(prepared: prepared, options: options, marks: marks, measureTints: measureTints,
                          first: tileFirst, last: tileLast)
                    .equatable()
                CursorOverlay(spot: spot, scale: scale, color: options.cursorColor, origin: CGPoint(x: 0, y: region.minY))
            }
            .frame(width: contentWidth, height: height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                // Pinned to the viewport's left edge: the content is offset by -off, so this is shifted back by +off.
                if let bg = options.stickyBackground, let ctx = prepared.layout.stickyHeaderContexts(atX: off / scale) {
                    StickyHeaderView(prepared: prepared, contexts: ctx, scale: scale, region: region,
                                     ink: options.ink ?? .primary, background: bg)
                        .equatable()
                        .offset(x: off)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in
                manualOffset = nil
                onTap(CGPoint(x: v.location.x, y: v.location.y + region.minY * scale))
            })
            .offset(x: -off)
        }
        .frame(width: viewport.width, height: height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10).onChanged { v in
                let base = dragBase ?? manualOffset ?? (animated ? target(source.spot(in: prepared.layout, at: Date())) : shown)
                dragBase = base
                manualOffset = clamped(base - v.translation.width)
            }.onEnded { _ in dragBase = nil }
        )
        .onChange(of: staticTarget, initial: true) { old, new in
            if animated || dragBase != nil || abs(new - old) < 0.01 || abs(new - shown) > viewport.width {
                shown = new
            } else {
                withAnimation(.easeOut(duration: 0.2)) { shown = new }
            }
        }
        .onChange(of: animated) { _, _ in shown = staticTarget }
        .onChange(of: viewport.width) { _, _ in shown = staticTarget }
    }
}
#endif
