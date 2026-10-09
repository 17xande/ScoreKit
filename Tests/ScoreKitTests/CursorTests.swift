import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S4d: cursor spots, hit testing, single-line scrolling.

private let cursorStarters = ["bach-prelude-in-c.musicxml", "minuet-in-g.musicxml", "ode-to-joy.musicxml", "twinkle-twinkle.musicxml"]

private func mini(_ body: String) throws -> Score {
    let xml = "<?xml version=\"1.0\"?><score-partwise version=\"4.0\"><part-list><score-part id=\"P1\"><part-name>P</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>1</divisions><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>\(body)</measure></part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func staffMiddle(_ l: ScoreLayout, _ s: Int) -> Double {
    let st = l.systems[s].staves
    return st[0].top + (st[st.count - 1].top + 4 - st[0].top) / 2
}

@Test("cursorSpot: every entry of every parity fixture has one, inside its system, x non-decreasing in a measure", arguments: walkNames)
func spotsForParityFixtures(name: String) throws {
    let (score, timeline, _) = try loadTimeline(name)
    let layout = score.layout(LayoutOptions(width: .fixed(100)))
    var last: (played: Int, x: Double)?
    for (i, e) in timeline.entries.enumerated() {
        let spot = try #require(layout.cursorSpot(timeline: timeline, entryIndex: i), "\(name) entry \(i)")
        let frame = try #require(layout.systemFrame(spot.systemIndex))
        #expect(spot.x >= frame.minX && spot.x <= frame.maxX, "\(name) entry \(i) x")
        #expect(spot.top >= frame.minY - 1e-9 && spot.top + spot.height <= frame.maxY + 1e-9, "\(name) entry \(i) y")
        #expect(layout.systemIndex(forMeasure: e.measureIndex) == spot.systemIndex)
        if let l = last, l.played == e.playedMeasureIndex {
            #expect(spot.x >= l.x - 1e-9, "\(name) entry \(i) went back")
        }
        last = (e.playedMeasureIndex, spot.x)
    }
    #expect(layout.cursorSpot(timeline: timeline, entryIndex: timeline.entries.count) == nil)
}

@Test("cursorSpot: rest-only entries and undrawn positions interpolate; unlaid measures give nil")
func spotsForRestsAndGaps() throws {
    let s = try mini("<note><rest/><duration>2</duration><type>half</type></note><note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><type>half</type></note>")
    let l = s.layout(.default)
    let a = try #require(l.cursorSpot(measureIndex: 0, position: Rational(0)))
    let b = try #require(l.cursorSpot(measureIndex: 0, position: Rational(1)))
    let c = try #require(l.cursorSpot(measureIndex: 0, position: Rational(2)))
    #expect(a.x < b.x && b.x < c.x)
    #expect(abs(b.x - (a.x + c.x) / 2) < 1e-9)
    #expect(l.cursorX(measureIndex: 0, position: 1.0)?.x == b.x)
    let half = try #require(l.cursorX(measureIndex: 0, position: 0.5))
    #expect(half.x > a.x && half.x < b.x)
    #expect(l.cursorSpot(measureIndex: 7, position: .zero) == nil)
    #expect(a.top == l.systems[0].staves[0].top && a.height == 4)
    #expect(a.bandRect.width == 3 && abs(a.bandRect.midX - (a.x + 1.18 / 2)) < 1e-9)
}

@Test("cursor band spans both staves of a grand staff, or just the selected one")
func spotHeight() throws {
    let score = try Score.load(data: fixture("minuet-in-g.musicxml"))
    let both = score.layout(.default)
    let st = both.systems[0].staves
    let spot = try #require(both.cursorSpot(measureIndex: 0, position: .zero))
    #expect(spot.top == st[0].top && abs(spot.height - (st[1].top + 4 - st[0].top)) < 1e-9)
    let one = score.layout(LayoutOptions(staves: [.init(part: 0, staff: 2)]))
    let s1 = try #require(one.cursorSpot(measureIndex: 0, position: .zero))
    #expect(one.systems[0].staves.count == 1)
    #expect(abs(s1.height - 4) < 1e-9, "height \(s1.height)")
}

@Test("glideSpot glides within a system, never across a break or backwards")
func glide() throws {
    let (score, timeline, _) = try loadTimeline("ode-to-joy")
    let layout = score.layout(LayoutOptions(width: .fixed(60)))
    #expect(layout.systems.count > 1)
    var crossed = 0, glided = 0
    for (a, b) in zip(timeline.entries, timeline.entries.dropFirst()) {
        let sa = try #require(layout.cursorSpot(for: a)), sb = try #require(layout.cursorSpot(for: b))
        let mid = try #require(layout.glideSpot(from: a, to: b, fraction: 0.5))
        #expect(layout.glideSpot(from: a, to: b, fraction: 0) == sa)
        #expect(layout.glideSpot(from: a, to: b, fraction: 1) == sb)
        if sa.systemIndex != sb.systemIndex {
            crossed += 1
            #expect(mid == sa)
        } else if sb.x > sa.x {
            glided += 1
            #expect(mid.x > sa.x && mid.x < sb.x)
        }
    }
    #expect(crossed > 0 && glided > 0)
}

@Test("glideSpot: the last entry glides toward the end of its note, capped at the barline")
func glideLast() throws {
    let (score, timeline, _) = try loadTimeline("twinkle-twinkle")
    let layout = score.layout(.default)
    let last = try #require(timeline.entries.last)
    let a = try #require(layout.cursorSpot(for: last))
    let mid = try #require(layout.glideSpot(from: last, to: nil, fraction: 0.5))
    let end = try #require(layout.glideSpot(from: last, to: nil, fraction: 1))
    let bar = try #require(layout.measureXRange(last.measureIndex)).upperBound
    #expect(mid.x > a.x && mid.x < end.x)
    #expect(end.x > a.x && end.x <= bar + 1e-9)
    #expect(layout.glideSpot(from: last, to: nil, fraction: 7)?.x == end.x)
}

@Test("glideSpot on repeats: holds on a backward jump and on a forward jump over a skipped measure")
func glideJumps() throws {
    let (score, timeline, _) = try loadTimeline("voltas")
    let layout = score.layout(.singleLine)
    var back = 0, skip = 0, forward = 0
    for (a, b) in zip(timeline.entries, timeline.entries.dropFirst()) {
        let sa = try #require(layout.cursorSpot(for: a)), sb = try #require(layout.cursorSpot(for: b))
        let mid = try #require(layout.glideSpot(from: a, to: b, fraction: 0.5))
        let dp = b.playedMeasureIndex - a.playedMeasureIndex, dw = b.measureIndex - a.measureIndex
        if dw < 0 || (dw == 0 && dp > 0) {
            back += 1
            #expect(mid == sa && layout.glideSpot(from: a, to: b, fraction: 1) == sb)
        } else if dw > 1 {
            skip += 1
            #expect(mid == sa && layout.glideSpot(from: a, to: b, fraction: 1) == sb)
        } else if sb.x > sa.x {
            forward += 1
            #expect(mid.x > sa.x && mid.x < sb.x)
        }
    }
    #expect(back > 0 && skip > 0 && forward > 0, "back \(back) skip \(skip) forward \(forward)")
}

@Test("hitTest: the centre of every drawn head hits that note; shared unisons hit the first", arguments: cursorStarters)
func hitCentres(file: String) throws {
    let score = try Score.load(data: fixture(file))
    let layout = score.layout(LayoutOptions(width: .fixed(100)))
    var checked = 0
    for (id, ln) in layout.notes where !ln.isRest {
        let hit = try #require(layout.hitTest(CGPoint(x: ln.headBox.midX, y: ln.headBox.midY)), "\(file) note \(id.value)")
        #expect(hit.noteID == (layout.sharedHeads[id] ?? id), "\(file) note \(id.value)")
        #expect(hit.systemIndex == ln.systemIndex)
        checked += 1
    }
    #expect(checked > 50)
}

@Test("hitTest: a shared unison maps to the first note")
func hitSharedUnison() throws {
    let score = try Score.load(data: fixture("layout/voices-two.musicxml"))
    let layout = score.layout(.default)
    for (second, first) in layout.sharedHeads {
        let b = try #require(layout.notes[second]).headBox
        let hit = try #require(layout.hitTest(CGPoint(x: b.midX, y: b.midY)))
        #expect(hit.noteID == first)
    }
}

@Test("hitTest: between notes gives the nearest; outside systems gives nil")
func hitBetween() throws {
    let s = try mini("<note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><type>half</type></note><note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><type>half</type></note>")
    let l = s.layout(.default)
    let ids = s.parts[0].measures[0].notes.map(\.id)
    let a = try #require(l.notes[ids[0]]).headBox, b = try #require(l.notes[ids[1]]).headBox
    let y = a.midY
    let nearA = try #require(l.hitTest(CGPoint(x: a.maxX + (b.minX - a.maxX) * 0.25, y: y)))
    let nearB = try #require(l.hitTest(CGPoint(x: a.maxX + (b.minX - a.maxX) * 0.75, y: y)))
    #expect(nearA.noteID == ids[0] && nearA.position == .zero)
    #expect(nearB.noteID == ids[1] && nearB.position == Rational(2))
    // Above the staff within the system's frame is still a hit by column.
    #expect(l.hitTest(CGPoint(x: b.midX, y: l.systems[0].staves[0].top - 1))?.noteID == ids[1])
    // Outside any system, or too far from every note.
    #expect(l.hitTest(CGPoint(x: -5, y: y)) == nil)
    #expect(l.hitTest(CGPoint(x: b.midX, y: l.systems[0].frame.maxY + 20)) == nil)
    #expect(l.hitTest(CGPoint(x: l.systems[0].frame.maxX + 5, y: y)) == nil)
    // Within a system a tap always lands: past the last note, on the last column.
    let past = try #require(l.hitTest(CGPoint(x: l.systems[0].frame.maxX - 0.2, y: y), tolerance: 0.1))
    #expect(past.noteID == ids[1])
    // Before the first note (in the clef area), the first column.
    #expect(l.hitTest(CGPoint(x: 0.1, y: y), tolerance: 0.1)?.noteID == ids[0])
}

@Test("hitTest: a tie, beam or stem is not a target (the point resolves to a note by column)", arguments: ["twinkle-twinkle.musicxml"])
func hitIgnoresInk(file: String) throws {
    let score = try Score.load(data: fixture(file))
    let layout = score.layout(.default)
    for case .beam(let els, _) in layout.systems.flatMap(\.items) {
        guard case .move(let p) = els[0] else { continue }
        let hit = layout.hitTest(p)
        #expect(hit == nil || layout.notes[hit!.noteID] != nil)
    }
}

@Test("cursorSpot then hitTest returns a note of that entry, or its measure and position", arguments: ["twinkle-twinkle", "ode-to-joy", "minuet-in-g", "bach-prelude-in-c", "chord", "two-part-piano", "pickup", "grace", "tuplet", "voltas", "voice-piano", "measure-rest"])
func roundTrip(name: String) throws {
    let (score, timeline, _) = try loadTimeline(name)
    let layout = score.layout(LayoutOptions(width: .fixed(100)))
    for (i, e) in timeline.entries.enumerated() {
        let spot = try #require(layout.cursorSpot(for: e))
        // The middle of the staff holding the entry's first note (the system's middle for a rest).
        let y = e.notes.first.flatMap { layout.notes[$0.id] }.map { layout.systems[spot.systemIndex].staves[$0.staffIndex].top + 2 }
            ?? staffMiddle(layout, spot.systemIndex)
        let ids = Set(e.notes.map(\.id))
        let hit = try #require(layout.hitTest(CGPoint(x: spot.x + 0.6, y: y)), "\(name) entry \(i)")
        let note = try #require(layout.notes[hit.noteID])
        if ids.isEmpty {
            #expect(hit.measureIndex == e.measureIndex && hit.position == e.position, "\(name) entry \(i): rest-only")
        } else {
            #expect(ids.contains(hit.noteID) && !note.isRest, "\(name) entry \(i): hit m\(hit.measureIndex) @\(hit.position), entry m\(e.measureIndex) @\(e.position)")
        }
    }
}

@Test("hitTest: the gap between systems and just above a staff belong to the nearest system")
func hitGaps() throws {
    let score = try Score.load(data: fixture("ode-to-joy.musicxml"))
    let layout = score.layout(LayoutOptions(width: .fixed(60)))
    #expect(layout.systems.count > 1)
    let a = layout.systems[0], b = layout.systems[1]
    let x = a.measures[0].bodyStart + 3
    let nearA = layout.hitTest(CGPoint(x: x, y: a.frame.maxY + 1))
    let nearB = layout.hitTest(CGPoint(x: x, y: b.frame.minY - 1))
    #expect(nearA?.systemIndex == 0 && nearB?.systemIndex == 1)
    #expect(layout.hitTestMeasure(CGPoint(x: x, y: a.frame.maxY + 1)) == a.measures[0].index)
    #expect(layout.hitTestMeasure(CGPoint(x: x, y: b.frame.minY - 1)) == b.measures[0].index)
    #expect(layout.hitTest(CGPoint(x: x, y: a.staves[0].top - 1))?.systemIndex == 0)
    // Far above everything, and far below, miss.
    #expect(layout.hitTest(CGPoint(x: x, y: a.frame.minY - 30)) == nil)
    #expect(layout.hitTest(CGPoint(x: x, y: layout.systems.last!.frame.maxY + 30)) == nil)
}

@Test("hitTest: mid-measure on a whole note, and past the last note before the barline")
func hitWholeAndEdge() throws {
    let s = try mini("<note><pitch><step>C</step><octave>5</octave></pitch><duration>4</duration><type>whole</type></note>")
    let l = s.layout(.default)
    let m = l.systems[0].measures[0]
    let y = l.systems[0].staves[0].top + 2
    let mid = try #require(l.hitTest(CGPoint(x: (m.bodyStart + m.barX) / 2, y: y)))
    #expect(mid.measureIndex == 0 && mid.position == .zero && !mid.isRest)
    let edge = try #require(l.hitTest(CGPoint(x: m.barX - 0.3, y: y), tolerance: 0.1))
    #expect(edge.position == .zero)
}

@Test("hitTest: a rest or grace note reports the seek position; a pitched note beats a rest in its column")
func hitRestAndGrace() throws {
    let score = try Score.load(data: fixture("edge/grace.musicxml"))
    let layout = score.layout(.default)
    let timeline = Timeline(score: score)
    var graces = 0
    for (id, n) in layout.notes where n.isGrace {
        graces += 1
        let hit = try #require(layout.hitTest(CGPoint(x: n.headBox.midX, y: n.headBox.midY)))
        #expect(hit.noteID == id && hit.isGrace)
        // The seek key is an entry of the timeline.
        #expect(timeline.entries.contains { $0.measureIndex == hit.measureIndex && $0.position == hit.position })
    }
    #expect(graces == 2)
    // A rest alone is hit, with its position; a second voice's pitched note at the same column wins.
    let rest = try mini("<note><rest/><duration>2</duration><type>half</type></note><note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><type>half</type></note>")
    let rl = rest.layout(.default)
    let restNote = try #require(rl.notes.values.first { $0.isRest })
    let rh = try #require(rl.hitTest(CGPoint(x: restNote.headBox.midX, y: restNote.headBox.midY)))
    #expect(rh.isRest && rh.position == .zero)
    let two = try mini("<note><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>half</type></note><note><pitch><step>F</step><octave>5</octave></pitch><duration>2</duration><voice>1</voice><type>half</type></note><backup><duration>4</duration></backup><note><rest/><duration>2</duration><voice>2</voice><type>half</type></note><note><rest/><duration>2</duration><voice>2</voice><type>half</type></note>")
    let tl = two.layout(.default)
    let r2 = try #require(tl.notes.values.first { $0.isRest })
    let h2 = try #require(tl.hitTest(CGPoint(x: r2.headBox.midX, y: r2.headBox.midY)))
    #expect(!h2.isRest)
    #expect(h2.staffIndex == 0 && h2.partIndex == 0)
}

@Test("hitTestMeasure: each measure's x range maps back to it; outside systems is nil", arguments: cursorStarters)
func measureHits(file: String) throws {
    let score = try Score.load(data: fixture(file))
    let layout = score.layout(LayoutOptions(width: .fixed(100)))
    for (si, sys) in layout.systems.enumerated() {
        for m in sys.measures {
            let r = try #require(layout.measureXRange(m.index))
            #expect(r == m.x0...m.barX)
            #expect(layout.systemIndex(forMeasure: m.index) == si)
            let p = CGPoint(x: (r.lowerBound + r.upperBound) / 2, y: sys.staves[0].top + 2)
            #expect(layout.hitTestMeasure(p) == m.index)
        }
    }
    #expect(layout.hitTestMeasure(CGPoint(x: 10, y: -50)) == nil)
    #expect(layout.systemIndex(forMeasure: 9999) == nil && layout.measureXRange(9999) == nil)
    #expect(layout.systemFrame(layout.systems.count) == nil && layout.systemFrame(0) == layout.systems[0].frame)
}

@Test("single line: x is strictly increasing along measures and the cursor", arguments: cursorStarters + ["layout/compound-6-8.musicxml"])
func singleLineMonotonic(file: String) throws {
    let score = try Score.load(data: fixture(file))
    let layout = score.layout(.singleLine)
    #expect(layout.systems.count == 1)
    var last = -Double.infinity
    for m in layout.systems[0].measures {
        #expect(m.x0 >= last - 1e-9 && m.bodyStart >= m.x0 && m.barX > m.bodyStart)
        for c in m.columns { #expect(c.x > last - 1e-9); last = c.x }
        last = max(last, m.barX)
    }
    let timeline = Timeline(score: score)
    var prev = -Double.infinity
    for e in timeline.entries where e.playedMeasureIndex == e.measureIndex {
        let x = try #require(layout.cursorSpot(for: e)).x
        #expect(x >= prev - 1e-9)
        prev = x
    }
}

@Test("scrollOffset keeps the cursor at the anchor and clamps to the content")
func scrolling() throws {
    let score = try Score.load(data: fixture("twinkle-twinkle.musicxml"))
    let layout = score.layout(.singleLine)
    let w = layout.size.width
    let vp = 40.0
    #expect(w > vp * 2)
    #expect(layout.scrollOffset(forCursorX: 3, viewportWidth: vp) == 0)
    #expect(abs(layout.scrollOffset(forCursorX: 100, viewportWidth: vp) - (100 - 8)) < 1e-9)
    #expect(layout.scrollOffset(forCursorX: 100, viewportWidth: vp, anchor: 0.5) == 80)
    #expect(layout.scrollOffset(forCursorX: w, viewportWidth: vp) == w - vp)
    #expect(layout.scrollOffset(forCursorX: 50, viewportWidth: w + 10) == 0)
}
