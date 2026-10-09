#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
@testable import ScoreKit

// Geometric collision checks over a `ScoreLayout`: what a good engraver never leaves overlapping on
// one staff (noteheads, stems, rests, accidentals and dots of different voices and chords).

struct Ink {
    enum Kind: String { case head, accidental, dot, stem, flag, rest }
    var kind: Kind
    var note: NoteID        // the note the item belongs to (a stem: the group's lead)
    var group: NoteID
    var system: Int
    var staff: Int
    var rect: CGRect
}

struct Clash: CustomStringConvertible {
    var a: Ink, b: Ink
    var measure: Int?       // 0-based
    var description: String {
        "m\((measure ?? -1) + 1) \(a.kind)(\(a.note.value))x\(b.kind)(\(b.note.value)) staff \(a.staff) at x=\(String(format: "%.2f", a.rect.midX)) y=\(String(format: "%.2f", a.rect.midY))"
    }
}

func inkItems(_ layout: ScoreLayout) -> [Ink] {
    var out: [Ink] = []
    for (si, sys) in layout.systems.enumerated() {
        for it in sys.items {
            let nid = it.noteID, gid = it.groupID
            guard nid != nil || gid != nil else { continue }
            guard let n = layout.notes[nid ?? gid!] else { continue }
            let group = n.groupID
            var kind: Ink.Kind?
            switch it {
            case .glyph(let cp, _, _, let note, _):
                if (0xE0A0...0xE0AF).contains(cp) { kind = .head }
                else if (0xE260...0xE26F).contains(cp) { kind = .accidental }
                else if cp == Glyph.augmentationDot.codepoint { kind = .dot }
                else if (0xE4E0...0xE4FF).contains(cp) { kind = .rest }
                else if (0xE240...0xE24F).contains(cp), note == nil { kind = .flag }
            case .line(let a, let b, _, _, _):
                if a.x == b.x, a.y != b.y { kind = .stem }
            default: break
            }
            guard let k = kind else { continue }
            out.append(Ink(kind: k, note: nid ?? gid!, group: group, system: si, staff: n.staffIndex, rect: it.bounds))
        }
    }
    return out
}

/// Overlaps that are not allowed. `tolerance` is how far two boxes may poke into each other
/// (touching and hairline overlaps are fine).
func clashes(_ layout: ScoreLayout, tolerance: Double = 0.06) -> [Clash] {
    let ink = inkItems(layout)
    var out: [Clash] = []
    let bySlot = Dictionary(grouping: ink, by: { "\($0.system)/\($0.staff)" })
    for (_, items) in bySlot {
        let sorted = items.sorted { $0.rect.minX < $1.rect.minX }
        for i in sorted.indices {
            for j in (i + 1)..<max(i + 1, sorted.count) {
                let a = sorted[i], b = sorted[j]
                if b.rect.minX > a.rect.maxX { break }
                let sameGroup = a.group == b.group
                // Within one chord only accidentals can collide with each other.
                // A dot also must not touch the stem or flag of its own chord.
                let dotVsStem = (a.kind == .dot && (b.kind == .flag || b.kind == .stem)) || (b.kind == .dot && (a.kind == .flag || a.kind == .stem))
                if sameGroup && !(a.kind == .accidental && b.kind == .accidental && a.note != b.note) && !dotVsStem { continue }
                // Flags and stems of one group, ledger lines etc. are exempt (same group).
                let r = a.rect.insetBy(dx: tolerance, dy: tolerance)
                guard r.intersects(b.rect.insetBy(dx: tolerance, dy: tolerance)) else { continue }
                // The only pairs that matter: skip a stem against a flag/dot of another group? No: keep all.
                out.append(Clash(a: a, b: b, measure: layout.noteTimes[a.note]?.measureIndex))
            }
        }
    }
    return out
}

/// Options for a fixed-width layout of the piano part(s) only.
func pianoOptions(_ s: Score, width: Double = 100) -> LayoutOptions {
    var o = LayoutOptions(width: .fixed(width))
    o.restrict(toPianoOf: s)
    return o
}

// MARK: Notation marks (slurs, dynamics, hairpins, octave lines, pedal)

struct MarkClash: CustomStringConvertible {
    var mark: LaidMark.Kind
    var other: String       // "head", "stem", ... or the other mark's kind, or "text"
    var system: Int
    var staff: Int
    var x: Double, y: Double
    var description: String {
        "sys \(system) staff \(staff) \(mark)x\(other) at x=\(String(format: "%.2f", x)) y=\(String(format: "%.2f", y))"
    }
}

/// The ink of an item as boxes: a glyph or text by its box; a slanted line and a path by boxes along
/// them (so a long slur does not count as the whole area under it).
func inkShapes(_ it: LayoutItem) -> [CGRect] {
    func along(_ pts: [CGPoint], _ r: Double) -> [CGRect] {
        var out: [CGRect] = []
        var prev: CGPoint?
        for p in pts {
            if let q = prev, hypot(p.x - q.x, p.y - q.y) > 0.01 {
                let n = max(1, Int(ceil(hypot(p.x - q.x, p.y - q.y) / 0.1)))
                for i in 0...n {
                    let t = Double(i) / Double(n)
                    out.append(CGRect(x: q.x + (p.x - q.x) * t - r, y: q.y + (p.y - q.y) * t - r, width: 2 * r, height: 2 * r))
                }
            } else if prev == nil { out.append(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            prev = p
        }
        return out
    }
    switch it {
    case .line(let a, let b, let t, _, _) where a.x != b.x && a.y != b.y: return along([a, b], t / 2)
    case .path(let els, let stroke, _, _, _): return along(Engraving.flatten(els), (stroke ?? 0) / 2)
    default: let b = it.bounds; return b.isNull ? [] : [b]
    }
}

/// What a notation mark must not overlap on its staff: noteheads, accidentals, dots, stems, flags,
/// beams, rests, ledger lines, ties and fingering of the staff's notes; other marks (slurs may
/// cross each other); and the tempo and jump text over the first staff. Cross-staff slurs are
/// not checked. `tolerance` is how far two boxes may poke into each other.
func markClashes(_ layout: ScoreLayout, tolerance: Double = 0.06) -> [MarkClash] {
    var out: [MarkClash] = []
    for (si, sys) in layout.systems.enumerated() {
        var markOf: [Int: Int] = [:]
        for (mi, m) in sys.marks.enumerated() { for i in m.items { markOf[i] = mi } }
        // Ink of the notes, by staff.
        var ink: [Int: [(rect: CGRect, what: String)]] = [:]
        var texts: [CGRect] = []
        for (i, it) in sys.items.enumerated() where markOf[i] == nil {
            if case .text = it { texts.append(it.bounds); continue }
            var staff: Int?
            if let id = it.noteID ?? it.groupID { staff = layout.notes[id]?.staffIndex }
            if let b = it.beamID, let g = layout.beams[b]?.first { staff = layout.notes[g]?.staffIndex }
            guard let st = staff else { continue }
            let what: String
            switch it {
            case .glyph: what = "glyph"
            case .line(let a, let b, _, _, _): what = a.x == b.x ? "stem" : "ledger"
            case .beam: what = "beam"
            default: what = "path"
            }
            for r in inkShapes(it) { ink[st, default: []].append((r, what)) }
        }
        for (mi, m) in sys.marks.enumerated() where m.kind != .crossStaffSlur {
            let shapes = m.items.flatMap { inkShapes(sys.items[$0]) }
            for s in shapes {
                let r = s.insetBy(dx: tolerance, dy: tolerance)
                for (rect, what) in ink[m.staffIndex] ?? [] where r.intersects(rect.insetBy(dx: tolerance, dy: tolerance)) {
                    out.append(MarkClash(mark: m.kind, other: what, system: si, staff: m.staffIndex, x: s.midX, y: s.midY))
                }
                if m.staffIndex == 0 {
                    for t in texts where r.intersects(t.insetBy(dx: tolerance, dy: tolerance)) {
                        out.append(MarkClash(mark: m.kind, other: "text", system: si, staff: 0, x: s.midX, y: s.midY))
                    }
                }
            }
            for (mj, n) in sys.marks.enumerated() where mj > mi && n.staffIndex == m.staffIndex && n.kind != .crossStaffSlur
                && !(m.kind == .slur && n.kind == .slur) {
                let other = n.items.flatMap { inkShapes(sys.items[$0]) }
                if let hit = shapes.first(where: { s in other.contains { s.insetBy(dx: tolerance, dy: tolerance).intersects($0.insetBy(dx: tolerance, dy: tolerance)) } }) {
                    out.append(MarkClash(mark: m.kind, other: "\(n.kind)", system: si, staff: m.staffIndex, x: hit.midX, y: hit.midY))
                }
            }
        }
    }
    return out
}
