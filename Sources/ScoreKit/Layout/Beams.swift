import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension Glyph {
    static func flag(levels: Int, up: Bool) -> Glyph? {
        switch (levels, up) {
        case (1, true): .flag8thUp
        case (1, false): .flag8thDown
        case (2, true): .flag16thUp
        case (2, false): .flag16thDown
        case (3, true): .flag32ndUp
        case (3, false): .flag32ndDown
        case (4, true): .flag64thUp
        case (4, false): .flag64thDown
        case (5..., true): .flag128thUp
        case (5..., false): .flag128thDown
        default: nil
        }
    }

    static func tupletDigit(_ d: Int) -> Glyph {
        [.tuplet0, .tuplet1, .tuplet2, .tuplet3, .tuplet4, .tuplet5, .tuplet6, .tuplet7, .tuplet8, .tuplet9][d]
    }
}

extension Engraving {
    static let beamHook = 1.0
    static let maxBeamSlope = 1.0

    /// Beam geometry: one straight line for the group's outer beam. The slope follows Gould
    /// (a second 1/4 sp, a third 1/2, a fourth 3/4, at most 1 sp) and is flat for concave
    /// patterns. Both ends sit on staff lines (hang, sit or straddle, never a sliver), and
    /// the stems are cut to the line. Secondary beams stack toward the heads.
    func layoutBeam(_ b: BeamGroup, _ pidx: [Int], _ placed: inout [PlacedGroup], _ buf: inout StaffBuffer) {
        let ms = b.members.map { pidx[$0] }
        guard ms.count >= 2, ms.allSatisfy({ $0 >= 0 && placed[$0].stem != nil }) else { return }
        let up = b.stemUp
        let scale = placed[ms[0]].group.scale
        let thick = EngravingDefaults.beamThickness * scale, gap = EngravingDefaults.beamSpacing * scale
        let minLen = (stemLength + Double(max(0, b.maxLevel - 2)) * (EngravingDefaults.beamThickness + EngravingDefaults.beamSpacing)) * scale
        let xs = ms.map { placed[$0].stem!.x }
        let tips: [Double] = ms.map { m in
            let g = placed[m].group
            if up { return min(StaffGeometry.y(g.notes.last!.p) - minLen, 2) }
            return max(StaffGeometry.y(g.notes.first!.p) + minLen, 2)
        }
        let x1 = xs[0], x2 = xs[xs.count - 1]
        let width = x2 - x1
        // Slope from the interval between the end tips; flat when an inner note sticks out past both ends.
        let span = tips[tips.count - 1] - tips[0]
        let inner = tips.dropFirst().dropLast()
        let concave = up ? inner.contains { $0 < min(tips[0], tips[tips.count - 1]) - 1e-6 }
                         : inner.contains { $0 > max(tips[0], tips[tips.count - 1]) + 1e-6 }
        let steps = Double(Int((abs(span) / 0.5).rounded()))
        let cap = min(Self.maxBeamSlope, 0.25 * width)   // short beams slope less
        var want = concave ? 0 : (span < 0 ? -1 : 1) * min(steps * 0.25, cap)
        want = (want / 0.25).rounded(.towardZero) * 0.25
        let s = width > 0 ? want / width : 0
        // The ideal line, just long enough for every stem; then both ends move outward onto the grid.
        let a = up ? zip(xs, tips).map { $1 - s * ($0 - x1) }.min()! : zip(xs, tips).map { $1 - s * ($0 - x1) }.max()!
        let bEnd = a + want
        let okMods: [Double] = up ? [0, 0.5, 0.75] : [0, 0.25, 0.5]
        func onGrid(_ v: Double) -> Bool {
            let m = ((v.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
            return okMods.contains { abs($0 - m) < 1e-6 || abs($0 - m + 1) < 1e-6 }
        }
        func candidates(_ ideal: Double) -> [Double] {
            let base = (ideal * 4).rounded() / 4
            return stride(from: 0.0, through: 1.75, by: 0.25).map { up ? base - $0 : base + $0 }
                .filter { onGrid($0) && (up ? $0 <= ideal + 1e-9 : $0 >= ideal - 1e-9) }
        }
        var best: (l: Double, r: Double, cost: Double)?
        for l in candidates(a) {
            for r in candidates(bEnd) {
                let d = r - l
                let inRange = want >= 0 ? (d >= -1e-9 && d <= want + 1e-9) : (d <= 1e-9 && d >= want - 1e-9)
                guard inRange else { continue }
                let cost = abs(l - a) + abs(r - bEnd) + 1.5 * abs(d - want)
                if best == nil || cost < best!.cost - 1e-9 { best = (l, r, cost) }
            }
        }
        let left = best?.l ?? a, right = best?.r ?? a
        func line(_ x: Double) -> Double { width > 0 ? left + (right - left) * (x - x1) / width : left }
        for (k, m) in ms.enumerated() { placed[m].stem!.yEnd = line(xs[k]); placed[m].beamed = true }

        let id = BeamID(placed[ms[0]].group.leadID.value)
        let st = placed[ms[0]].stem!.thickness
        for seg in b.segments {
            let off = Double(seg.level - 1) * (thick + gap)
            var xa = xs[seg.from] - st / 2, xb = xs[seg.to] + st / 2
            if seg.from == seg.to {
                if seg.forward { xb = xs[seg.from] + Self.beamHook * scale } else { xa = xs[seg.from] - Self.beamHook * scale }
            }
            func top(_ x: Double) -> Double { up ? line(x) + off : line(x) - off - thick }
            let els: [PathElement] = [
                .move(CGPoint(x: xa, y: top(xa))), .line(CGPoint(x: xb, y: top(xb))),
                .line(CGPoint(x: xb, y: top(xb) + thick)), .line(CGPoint(x: xa, y: top(xa) + thick)), .close,
            ]
            buf.items.append(.beam(els, beamID: id))
            buf.grow(CGRect(x: xa, y: min(top(xa), top(xb)), width: xb - xa, height: abs(top(xb) - top(xa)) + thick))
        }
        buf.beams[id] = ms.map { placed[$0].group.leadID }
    }

    // MARK: Tuplets

    func layoutTuplet(_ t: TupletSpan, _ pidx: [Int], _ placed: [PlacedGroup], _ buf: inout StaffBuffer) {
        let pgs = t.members.compactMap { pidx[$0] >= 0 ? placed[pidx[$0]] : nil }
        guard !pgs.isEmpty, pgs.count == t.members.count else { return }
        var x1 = Double.infinity, x2 = -Double.infinity
        var top = Double.infinity, bottom = -Double.infinity
        for pg in pgs {
            let g = pg.group
            if g.isRest {
                let w = Glyph.rest(g.value).metrics
                let y = ((g.value == .whole || g.value == .breve) ? 1.0 : 2.0) + g.restDY
                let box = w.box(at: CGPoint(x: pg.x, y: y))
                x1 = min(x1, box.minX); x2 = max(x2, box.maxX)
                top = min(top, box.minY); bottom = max(bottom, box.maxY)
                continue
            }
            x1 = min(x1, pg.x + g.baseDX + (g.notes.map(\.dx).min() ?? 0))
            x2 = max(x2, pg.x + g.baseDX + (g.notes.map(\.dx).max() ?? 0) + g.headWidth)
            top = min(top, StaffGeometry.y(g.notes.last!.p) - 0.5)
            bottom = max(bottom, StaffGeometry.y(g.notes.first!.p) + 0.5)
            if let s = pg.stem {
                x2 = max(x2, s.x + s.thickness / 2)
                top = min(top, s.yEnd); bottom = max(bottom, s.yEnd)
            }
        }
        guard x1 < x2 else { return }
        let digits = t.number > 0 ? String(t.number).compactMap(\.wholeNumberValue) : []
        let numW = digits.reduce(0) { $0 + Glyph.tupletDigit($1).metrics.advance }
        let mid = (x1 + x2) / 2
        func number(baseline: Double) {
            var cx = mid - numW / 2
            for d in digits {
                let g = Glyph.tupletDigit(d)
                let o = CGPoint(x: cx, y: baseline)
                buf.items.append(.glyph(codepoint: g.codepoint, position: o))
                buf.grow(g.metrics.box(at: o))
                cx += g.metrics.advance
            }
        }
        let thick = EngravingDefaults.tupletBracketThickness
        if !t.bracket {
            number(baseline: t.above ? top - 0.5 : bottom + 2.0)
            return
        }
        let yb = t.above ? top - 0.9 : bottom + 0.9
        let hook = t.above ? 0.8 : -0.8
        func seg(_ a: Double, _ b: Double) {
            buf.items.append(.line(from: CGPoint(x: a, y: yb), to: CGPoint(x: b, y: yb), thickness: thick))
        }
        if digits.isEmpty { seg(x1, x2) }
        else {
            let half = numW / 2 + 0.4
            seg(x1, mid - half); seg(mid + half, x2)
            number(baseline: yb + 0.75)
        }
        for x in [x1, x2] {
            buf.items.append(.line(from: CGPoint(x: x, y: yb), to: CGPoint(x: x, y: yb + hook), thickness: thick))
        }
        buf.grow(CGRect(x: x1, y: min(yb, yb + hook) - 0.8, width: x2 - x1, height: abs(hook) + 1.6))
    }
}
