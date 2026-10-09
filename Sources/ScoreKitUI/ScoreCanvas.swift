#if canImport(SwiftUI)
import ScoreKit
import SwiftUI

/// Draws a region of one `LaidSystem` with a `Canvas`: staff furniture, notes, ties, beams
/// and text, coloured by the documented policy (see `LayoutItem`). Unchanged inputs do not
/// redraw: the canvas compares its inputs (`Equatable`) and the layout by identity.
///
/// The view is `region.size * scale` points; `region` is in layout coordinates (staff spaces)
/// and defaults to the system frame with a vertical ink margin. Background is transparent.
public struct ScoreCanvas: View, Equatable {
    public var layout: PreparedLayout
    public var systemIndex: Int
    /// Points per staff space.
    public var scale: Double
    public var ink: Color
    public var noteColors: [NoteID: Color]
    public var groupColor: GroupColorPolicy
    /// Measure index to a tint drawn behind the notes (only this system's measures matter).
    public var measureTints: [Int: Color]
    public var region: CGRect

    public init(layout: PreparedLayout, systemIndex: Int, scale: Double, ink: Color = .primary,
                noteColors: [NoteID: Color] = [:], groupColor: GroupColorPolicy = .firstMarkedMember,
                measureTints: [Int: Color] = [:], region: CGRect? = nil) {
        self.layout = layout
        self.systemIndex = systemIndex
        self.scale = scale
        self.ink = ink
        // Only marks that can colour this system's items count, so a new mark redraws only
        // its own system.
        if noteColors.isEmpty || !layout.systemNoteIDs.indices.contains(systemIndex) {
            self.noteColors = [:]
        } else {
            let ids = layout.systemNoteIDs[systemIndex]
            self.noteColors = noteColors.filter { ids.contains($0.key) }
        }
        self.groupColor = groupColor
        let sys = layout.layout.systems.indices.contains(systemIndex) ? layout.layout.systems[systemIndex] : nil
        if let sys, !measureTints.isEmpty {
            let here = Set(sys.measures.map(\.index))
            self.measureTints = measureTints.filter { here.contains($0.key) }
        } else {
            self.measureTints = [:]
        }
        self.region = region ?? layout.lineRegion(systemIndex)
    }

    nonisolated public static func == (a: ScoreCanvas, b: ScoreCanvas) -> Bool {
        a.layout === b.layout && a.systemIndex == b.systemIndex && a.scale == b.scale && a.ink == b.ink
            && a.groupColor == b.groupColor && a.region == b.region && a.noteColors == b.noteColors
            && a.measureTints == b.measureTints
    }

    /// Use `.equatable()` where unchanged canvases should skip their body (`ScoreView` does).
    public var body: some View {
        let c = self
        Canvas { ctx, _ in c.draw(&ctx) }
            .frame(width: region.width * scale, height: region.height * scale)
            .accessibilityHidden(true)
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext) {
        let core = layout.layout
        guard core.systems.indices.contains(systemIndex) else { return }
        let sys = core.systems[systemIndex]
        let k = scale, ox = region.minX, oy = region.minY
        func P(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - ox) * k, y: (p.y - oy) * k) }
        func build(_ els: [PathElement]) -> Path {
            var path = Path()
            for e in els {
                switch e {
                case .move(let p): path.move(to: P(p))
                case .line(let p): path.addLine(to: P(p))
                case .quad(let to, let c): path.addQuadCurve(to: P(to), control: P(c))
                case .curve(let to, let c1, let c2): path.addCurve(to: P(to), control1: P(c1), control2: P(c2))
                case .close: path.closeSubpath()
                }
            }
            return path
        }

        // Measure tints, behind everything.
        if !measureTints.isEmpty, let first = sys.staves.first, let last = sys.staves.last {
            for m in sys.measures {
                guard let tint = measureTints[m.index] else { continue }
                let r = CGRect(x: m.x0, y: first.top - 2, width: m.barX - m.x0, height: last.top + 4 - first.top + 4)
                let device = CGRect(x: (r.minX - ox) * k, y: (r.minY - oy) * k, width: r.width * k, height: r.height * k)
                ctx.fill(Path(device), with: .color(tint))
            }
        }

        let xs = region.minX...region.maxX
        for entry in layout.systems[systemIndex] {
            if entry.maxX < xs.lowerBound || entry.minX > xs.upperBound { continue }
            let item = entry.item
            let shading = GraphicsContext.Shading.color(layout.color(of: item, ink: ink, marks: noteColors, policy: groupColor))
            switch item {
            case .glyph(let cp, let pos, let size, _, _):
                guard let outline = ScoreFont.outline(cp) else { continue }
                var c = ctx
                let p = P(pos)
                let s = (size ?? 4) / 4 * k
                c.translateBy(x: p.x, y: p.y)
                c.scaleBy(x: s, y: s)
                c.fill(outline, with: shading)
            case .line(let a, let b, let t, _, _):
                var path = Path()
                path.move(to: P(a)); path.addLine(to: P(b))
                ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: t * k, lineCap: .butt))
            case .rect(let r, _, _):
                ctx.fill(Path(CGRect(x: (r.minX - ox) * k, y: (r.minY - oy) * k, width: r.width * k, height: r.height * k)), with: shading)
            case .text(let s, let pos, let style):
                var t = Text(s).font(.system(size: style.size * k, design: .serif))
                if style.italic { t = t.italic() }
                if style.bold { t = t.bold() }
                let resolved = ctx.resolve(t.foregroundColor(ink))
                let m = resolved.measure(in: CGSize(width: 10_000, height: 10_000))
                let base = resolved.firstBaseline(in: m)
                let p = P(pos)
                let x: Double = switch style.anchor {
                case .start: p.x
                case .middle: p.x - m.width / 2
                case .end: p.x - m.width
                }
                ctx.draw(resolved, at: CGPoint(x: x, y: p.y - base), anchor: .topLeading)
            case .path(let els, let stroke, let fill, _, _):
                let path = build(els)
                if fill { ctx.fill(path, with: shading) }
                if let w = stroke {
                    ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: w * k, lineCap: .round, lineJoin: .round))
                }
            case .beam(let els, _):
                ctx.fill(build(els), with: shading)
            }
        }
    }
}
#endif
