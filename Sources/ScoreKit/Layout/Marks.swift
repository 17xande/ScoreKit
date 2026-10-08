import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A volta bracket over measures `start...end` (0-based, inclusive).
struct VoltaSpec {
    var start: Int
    var end: Int
    var label: String
    /// Closed with a hook at the end (`type="stop"`) rather than open (`discontinue`, or never closed).
    var closed: Bool
}

extension LaidMeasure {
    /// The x of a position (quarters into the measure), interpolated between the columns and
    /// the measure's ends. Clamped to the measure.
    public func x(at position: Rational) -> Double {
        var anchors: [(Rational, Double)] = columns.map { ($0.onset, $0.x) }
        if anchors.first.map({ $0.0 > .zero }) ?? true { anchors.insert((.zero, bodyStart), at: 0) }
        if anchors.last.map({ $0.0 < duration }) ?? true { anchors.append((duration, barX)) }
        if position <= anchors[0].0 { return anchors[0].1 }
        for i in 1..<anchors.count where position <= anchors[i].0 {
            let (p0, x0) = anchors[i - 1], (p1, x1) = anchors[i]
            return x0 + (x1 - x0) * ((position - p0).double / (p1 - p0).double)
        }
        return anchors[anchors.count - 1].1
    }
}

extension Engraving {
    // MARK: Planning

    /// Volta brackets from the endings of the first selected part. A volta with
    /// `print-object="no"` on its start is left out.
    static func planVoltas(_ score: Score, part: Int) -> [VoltaSpec] {
        var out: [VoltaSpec] = []
        var open: (start: Int, label: String, print: Bool)?
        let measures = score.parts[part].measures
        func close(_ end: Int, closed: Bool) {
            guard let o = open else { return }
            if o.print { out.append(VoltaSpec(start: o.start, end: max(o.start, end), label: o.label, closed: closed)) }
            open = nil
        }
        for (mi, m) in measures.enumerated() {
            for b in m.barlines {
                guard let e = b.ending else { continue }
                switch e.kind {
                case .start:
                    close(mi - 1, closed: false)
                    let label: String
                    if !e.text.isEmpty { label = e.text }
                    else if !e.numbers.isEmpty { label = e.numbers.map(String.init).joined(separator: ", ") + "." }
                    else { label = e.rawNumber.isEmpty ? "" : e.rawNumber + "." }
                    open = (mi, label, e.printObject)
                case .stop: close(mi, closed: true)
                case .discontinue: close(mi, closed: false)
                }
            }
        }
        close(measures.count - 1, closed: false)
        return out
    }

    // MARK: Placement

    /// The topmost ink of a staff buffer over an x range, never below the staff's top line (0).
    func skyline(_ buf: StaffBuffer, _ x0: Double, _ x1: Double) -> Double {
        var top = 0.0
        for it in buf.items {
            let b = it.bounds
            if b.isNull || b.maxX < x0 || b.minX > x1 { continue }
            top = min(top, b.minY)
        }
        return top
    }

    /// Direction marks, voltas, tempo and the measure number: everything that sits above the
    /// first staff. They go into that staff's buffer, so its extent (and so the staff distance
    /// and the system frame) covers them. Positions are staff-local. `limit` is the right edge
    /// text marks stay inside (the fixed page width less the margin); nil for a single line.
    func layoutOverlays(range: Range<Int>, measures: [MeasureData], laid: [LaidMeasure], limit: Double?,
                        buf: inout StaffBuffer) {
        let part = slots[0].part
        let measuresOfPart = score.parts[part].measures
        func lm(_ m: Int) -> LaidMeasure? { laid.first { $0.index == m } }
        func barLeft(_ m: Int) -> Double {
            guard let l = lm(m) else { return 0 }
            return l.barX - (measures[m].endFixed - measures[m].endClefW)
        }
        let gapUp = 0.5
        /// Keeps a mark of `width` starting at `x` inside the staff and the page.
        func clamp(_ x: Double, _ width: Double) -> Double {
            var x = x
            if let limit { x = min(x, limit - width) }
            return max(x, staffLeft + 0.2)
        }

        // Measure number at the system start.
        if options.showMeasureNumbers, range.lowerBound > 0 {
            let style = TextStyle(size: 1.7, italic: true)
            let text = measures[range.lowerBound].number
            let x = staffLeft + 0.2
            let sky = skyline(buf, x, x + style.estimatedWidth(of: text))
            buf.items.append(.text(text, position: CGPoint(x: x, y: min(-1.2, sky - 0.4)), style: style))
        }

        // Voltas first: one common height for the system.
        struct Seg { var x1: Double; var x2: Double; var spec: VoltaSpec; var startsHere: Bool; var endsHere: Bool }
        var segs: [Seg] = []
        for v in voltas where v.end >= range.lowerBound && v.start < range.upperBound {
            let a = max(v.start, range.lowerBound), b = min(v.end, range.upperBound - 1)
            guard let la = lm(a), let lb = lm(b) else { continue }
            let starts = v.start == a
            // A continued bracket starts after the clef and key; the end hook sits at the barline.
            segs.append(Seg(x1: starts ? la.x0 + 0.1 : la.bodyStart - 0.3, x2: lb.barX - EngravingDefaults.thinBarlineThickness / 2,
                            spec: v, startsHere: starts, endsHere: v.end == b))
        }
        if !segs.isEmpty {
            let hook = 1.5
            let sky = segs.map { skyline(buf, $0.x1, $0.x2) }.min()!
            let yb = min(-3.0, sky - gapUp - hook)
            let t = EngravingDefaults.repeatEndingLineThickness
            for s in segs {
                buf.items.append(.line(from: CGPoint(x: s.x1, y: yb), to: CGPoint(x: s.x2, y: yb), thickness: t))
                if s.startsHere {
                    buf.items.append(.line(from: CGPoint(x: s.x1, y: yb), to: CGPoint(x: s.x1, y: yb + hook), thickness: t))
                    if !s.spec.label.isEmpty {
                        buf.items.append(.text(s.spec.label, position: CGPoint(x: s.x1 + 0.5, y: yb + 1.35), style: TextStyle(size: 1.6)))
                    }
                }
                if s.spec.closed, s.endsHere {
                    buf.items.append(.line(from: CGPoint(x: s.x2, y: yb), to: CGPoint(x: s.x2, y: yb + hook), thickness: t))
                }
            }
        }

        // Tempo marks.
        for m in range where m < measuresOfPart.count {
            guard let l = lm(m) else { continue }
            for d in measuresOfPart[m].directions where d.source == .direction {
                let word = TextStyle(size: 2.0, bold: true)
                let plain = TextStyle(size: 2.0)
                var width = 0.0
                if let w = d.words { width += word.estimatedWidth(of: w) + 0.7 }
                var metro: (unit: Glyph, dots: Int, text: String)?
                if let mt = d.metronome, let unit = mt.beatUnit,
                   let pm = mt.perMinuteText?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? mt.perMinute.map({ $0 == $0.rounded() ? String(Int($0)) : String($0) }) {
                    let g: Glyph
                    switch unit {
                    case .breve, .whole: g = .metNoteWhole
                    case .half: g = .metNoteHalfUp
                    case .quarter: g = .metNoteQuarterUp
                    case .eighth: g = .metNote8thUp
                    default: g = .metNote16thUp
                    }
                    metro = (g, mt.dots, "= " + pm)
                    width += g.metrics.advance * Self.metSize / Glyph.standardSize
                        + Double(mt.dots) * (0.1 + Glyph.metAugmentationDot.metrics.advance * Self.metSize / Glyph.standardSize)
                        + 0.4 + plain.estimatedWidth(of: "= " + pm)
                }
                guard width > 0 else { continue }
                var pos = d.onset + d.offset
                if pos < .zero { pos = .zero }
                if pos > l.duration { pos = l.duration }
                let x0 = clamp(l.x(at: pos), width)
                let sky = skyline(buf, x0, x0 + width)
                let base = min(-1.2, sky - gapUp - 0.45)
                var x = x0
                if let w = d.words {
                    buf.items.append(.text(w, position: CGPoint(x: x, y: base), style: word))
                    x += word.estimatedWidth(of: w) + 0.7
                }
                if let mm = metro {
                    let k = Self.metSize / Glyph.standardSize
                    buf.items.append(.glyph(codepoint: mm.unit.codepoint, position: CGPoint(x: x, y: base), size: Self.metSize))
                    x += mm.unit.metrics.advance * k
                    for _ in 0..<mm.dots {
                        x += 0.1
                        buf.items.append(.glyph(codepoint: Glyph.metAugmentationDot.codepoint, position: CGPoint(x: x, y: base - 0.3), size: Self.metSize))
                        x += Glyph.metAugmentationDot.metrics.advance * k
                    }
                    buf.items.append(.text(mm.text, position: CGPoint(x: x + 0.4, y: base), style: plain))
                }
            }
        }

        // Jump marks (segno, coda, D.C., D.S., Fine, To Coda). Marks of one measure sit side by side.
        let all = score.parts[part].measures.flatMap(\.jumpMarks)
        let hasFine = all.contains { $0.kind == .fine }
        let hasToCoda = all.contains { $0.kind == .toCoda }
        let suffix = hasToCoda ? " al Coda" : (hasFine ? " al Fine" : "")
        let italic = TextStyle(size: 2.0, italic: true)
        for m in range where m < measuresOfPart.count {
            guard let l = lm(m) else { continue }
            var seen = Set<String>()
            var leftEnd = -Double.infinity       // where the left-anchored marks so far end
            var rightStart = Double.infinity     // where the right-anchored marks so far begin
            for j in measuresOfPart[m].jumpMarks {
                guard seen.insert("\(j.kind)@\(j.onset)").inserted else { continue }
                // D.C., D.S., Fine and To Coda say where to stop or jump: they end the measure.
                let atEnd = j.onset >= l.duration || [.dacapo, .dalsegno, .fine, .toCoda].contains(j.kind)
                var text: String?
                var glyph: (Glyph, Double)?
                switch j.kind {
                case .segno: glyph = (.segno, 4)
                case .coda: glyph = (.coda, 4)
                case .dacapo: text = "D.C." + suffix
                case .dalsegno: text = "D.S." + suffix
                case .fine: text = "Fine"
                case .toCoda: text = "To Coda"; glyph = (.coda, 3)
                }
                let k = (glyph?.1 ?? 4) / Glyph.standardSize
                let gw = glyph.map { $0.0.metrics.advance * k } ?? 0
                let tw = text.map { italic.estimatedWidth(of: $0) + (glyph != nil ? 0.4 : 0) } ?? 0
                let total = gw + tw
                var x0: Double
                if atEnd {
                    x0 = min(barLeft(m) - 0.3, rightStart) - total
                    rightStart = x0 - 0.6
                } else {
                    x0 = max(l.x(at: j.onset) - 0.2, leftEnd)
                    leftEnd = x0 + total + 0.6
                }
                x0 = clamp(x0, total)
                let sky = skyline(buf, x0, x0 + total)
                let base = min(-1.2, sky - gapUp - (glyph.map { -$0.0.metrics.minY * k } ?? 0.25 * italic.size))
                var x = x0
                if let t = text {
                    buf.items.append(.text(t, position: CGPoint(x: x, y: base), style: italic))
                    x += tw
                }
                if let g = glyph {
                    buf.items.append(.glyph(codepoint: g.0.codepoint, position: CGPoint(x: x, y: base), size: g.1 == 4 ? nil : g.1))
                }
            }
        }
    }

    static let metSize = 2.6
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
