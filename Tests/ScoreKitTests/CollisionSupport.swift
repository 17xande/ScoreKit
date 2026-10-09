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
