import Foundation
import Testing
@testable import ScoreKit

private func line(_ name: String) throws -> (Score, ScoreLayout) {
    let score = try Score.load(data: fixture(name))
    return (score, Engraver.layout(score, options: LayoutOptions(width: .singleLine)))
}

@Test("sticky context: a plain score keeps its clefs, key and time all along the line")
func stickyContextPlain() throws {
    let (score, l) = try line("minuet-in-g.musicxml")
    let ctx = l.stickyContext(atX: l.size.width - 1)
    #expect(ctx.count == score.parts[0].staves)
    #expect(ctx.map(\.clef.sign) == ["G", "F"])
    #expect(ctx.allSatisfy { $0.key.fifths == 1 && $0.time == TimeSignature(beats: 3, beatType: 4, symbol: nil) })
    // Left of everything: the first measure's start.
    #expect(l.stickyContext(atX: -5) == l.stickyContext(atX: 0))
    #expect(l.stickyContext(atX: 0, system: 3).isEmpty)
}

@Test("sticky header: none until the line is scrolled; then staff lines, clefs, key and time per staff")
func stickyHeaderLayout() throws {
    let (_, l) = try line("minuet-in-g.musicxml")
    #expect(l.stickyHeader(atX: 0) == nil)
    let h = try #require(l.stickyHeader(atX: 40))
    #expect(h.contexts.count == 2)
    let items = h.layout.systems[0].items
    // 5 staff lines per staff and the system barline; a clef each, 1 sharp each, 3 over 4 each (two digits).
    #expect(items.filter { if case .line = $0 { true } else { false } }.count == 11)
    // Seam: the clef, key and time sit exactly where the system start draws them, so pinning does not move them.
    let real = l.systems[0].items.filter { if case .glyph(let cp, _, _, nil, nil) = $0 { cp == Glyph.gClef.codepoint || cp == Glyph.accidentalSharp.codepoint } else { false } }
    for it in real.prefix(2) { #expect(items.contains(it)) }
    #expect(h.width > 3 && h.width < 12)
    #expect(h.layout.systems[0].frame.height == l.systems[0].frame.height)
    for it in items { #expect(it.bounds.maxX <= h.width + 0.01 && it.bounds.minX >= -0.01) }
}

@Test("sticky context: key and clef changes take over at their measure, per staff")
func stickyContextChanges() throws {
    let (score, l) = try line("complex/lilypond/13a-KeySignatures.mxl")
    let sys = l.systems[0]
    var changes = 0
    for (k, m) in sys.measures.enumerated() where k > 0 {
        let before = l.stickyContext(atX: sys.measures[k - 1].bodyStart + 0.01)
        let at = l.stickyContext(atX: m.bodyStart + 0.01)
        #expect(at.count == sys.staves.count)
        // The context at the start of a measure is the carried one, plus changes in the measure itself.
        let keyAtStart = score.parts[0].measures[m.index].keyChanges.last(where: { $0.onset == .zero })?.key
        if let keyAtStart {
            #expect(at[0].key == keyAtStart, "measure \(m.index)")
            if before[0].key != at[0].key { changes += 1 }
        }
    }
    #expect(changes > 3)
}

@Test("sticky context: clef changes inside a measure apply from their column", arguments: ["complex/openscore/stanford-sou-wester.mxl"])
func stickyContextMidMeasure(name: String) throws {
    let (_, l) = try line(name)
    var seen = 0
    for m in l.systems[0].measures {
        for c in m.contextChanges {
            // Just left of the change the old context holds; at it, the new one.
            let at = l.stickyContext(atX: c.x)[c.staff]
            #expect(at == c.context)
            seen += 1
        }
    }
    #expect(seen > 0)
}

private func gap(_ p: CGPoint, _ r: CGRect) -> Double { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }

@Test("slurs: every end lies within 1.6 sp (cross-staff) or 2.5 sp (others) of a notehead or stem tip",
      arguments: ["boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux", "schumann-widmung", "stanford-sou-wester"])
func slurEndsStayOnTheirNotes(name: String) throws {
    let score = try Score.load(data: fixture("complex/openscore/\(name).mxl"))
    var o = LayoutOptions(width: .fixed(80))
    o.restrict(toPianoOf: score)
    let l = score.layout(o)
    var checked = 0
    for (si, sys) in l.systems.enumerated() {
        let anchors = l.systemNotes[si].flatMap { n -> [(CGRect?, CGPoint?)] in [(n.headBox, nil), (nil, n.stemEnd)] }
        for m in sys.marks where m.kind == .slur || m.kind == .crossStaffSlur {
            for i in m.items {
                guard case .path(let els, _, _, _, _) = sys.items[i], case .move(let a)? = els.first,
                      case .curve(let b, _, _)? = els.dropFirst().first else { continue }
                for p in [a, b] {
                    // The halves of a slur across a system break end at the break, not on a note.
                    if p.x < (sys.measures.first?.bodyStart ?? 0) + 0.6 || p.x > (sys.measures.last?.barX ?? 1e9) - 0.6 { continue }
                    let d = anchors.map { $0.0.map { gap(p, $0) } ?? $0.1.map { hypot(p.x - $0.x, p.y - $0.y) } ?? 1e9 }.min() ?? 1e9
                    #expect(d <= (m.kind == .crossStaffSlur ? 1.6 : 2.5), "\(name) system \(si): slur end (\(p.x), \(p.y)) is \(d) sp from its notes")
                    checked += 1
                }
            }
        }
    }
    #expect(checked > 0)
}

@Test("sticky header: a key change hidden under the header is already in it")
func stickyContextUnderTheHeader() throws {
    let (_, l) = try line("complex/lilypond/13a-KeySignatures.mxl")
    let steps = l.systems[0].contextSteps
    let change = try #require(zip(steps, steps.dropFirst()).first { $0.0.contexts[0].key != $0.1.contexts[0].key }).1
    // Just left of the change, within the header's reach: the header already shows the new key.
    let ctx = try #require(l.stickyHeaderContexts(atX: change.x - 0.5))
    #expect(ctx[0].key == change.contexts[0].key)
    #expect(l.stickyContext(atX: change.x - 0.5)[0].key != change.contexts[0].key)
    #expect(l.stickyHeaderContexts(atX: 0) == nil)
    #expect(l.maxStickyHeaderWidth() > 4)
}
