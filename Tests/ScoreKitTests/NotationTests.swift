import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import ScoreKit

// S6c part 1: octave lines, pedal, slurs, dynamics and hairpins.

private let openScore = [
    "boulanger-parfois-je-suis-triste", "grandval-les-clochettes", "satie-je-te-veux",
    "schumann-widmung", "stanford-sou-wester",
]

/// A one-part piano score: `measures` are the inner XML of each 4/4 measure (divisions 1, treble
/// staff 1 only unless `staves` is 2).
private func score(_ measures: [String], staves: Int = 1) throws -> Score {
    let clefs = staves == 2 ? "<staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>F</sign><line>4</line></clef>"
                            : "<clef><sign>G</sign><line>2</line></clef>"
    var body = ""
    for (i, m) in measures.enumerated() {
        let attrs = i == 0 ? "<attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time>\(clefs)</attributes>" : ""
        body += "<measure number=\"\(i + 1)\">\(attrs)\(m)</measure>"
    }
    let xml = "<score-partwise><part-list><score-part id=\"P1\"><part-name>Piano</part-name></score-part></part-list><part id=\"P1\">\(body)</part></score-partwise>"
    return try Score.parse(xml: Data(xml.utf8))
}

private func note(_ step: String, _ oct: Int, dur: Int = 1, staff: Int = 1, extra: String = "", notations: String = "") -> String {
    "<note><pitch><step>\(step)</step><octave>\(oct)</octave></pitch><duration>\(dur)</duration><voice>1</voice><staff>\(staff)</staff>\(extra)\(notations.isEmpty ? "" : "<notations>\(notations)</notations>")</note>"
}
private func dir(_ inner: String, staff: Int = 1, placement: String? = nil, offset: Int? = nil) -> String {
    "<direction\(placement.map { " placement=\"\($0)\"" } ?? "")><direction-type>\(inner)</direction-type>\(offset.map { "<offset>\($0)</offset>" } ?? "")<staff>\(staff)</staff></direction>"
}
private func four(_ step: String, _ oct: Int, staff: Int = 1) -> String { (0..<4).map { _ in note(step, oct, staff: staff) }.joined() }

// MARK: Parsing

@Test("octave shift: 8va (type down) writes notes an octave lower, 15ma two, 8vb higher; the sounding pitch is untouched")
func octaveShiftParse() throws {
    let s = try score([
        dir("<octave-shift type=\"down\" size=\"8\" number=\"1\"/>") + note("C", 6) + note("D", 6) + dir("<octave-shift type=\"stop\" size=\"8\" number=\"1\"/>") + note("E", 6) + note("F", 6),
        dir("<octave-shift type=\"down\" size=\"15\" number=\"1\"/>") + four("C", 7),
        dir("<octave-shift type=\"up\" size=\"8\"/>") + four("C", 2),
    ])
    let p = s.parts[0]
    #expect(p.octaveShifts.map(\.octaves) == [-1, -2, 1])
    #expect(p.octaveShifts[0].start == ScorePosition(measure: 0, onset: .zero))
    #expect(p.octaveShifts[0].end == ScorePosition(measure: 0, onset: Rational(2)))
    // The last one is never stopped: it runs to the end of the part.
    #expect(p.octaveShifts[2].end == ScorePosition(measure: 2, onset: Rational(4)))
    let notes = p.measures.flatMap(\.notes)
    #expect(notes.map(\.displayOctaves) == [-1, -1, 0, 0, -2, -2, -2, -2, 1, 1, 1, 1])
    #expect(notes[0].pitch?.octave == 6)
}

@Test("octave shift: playback keeps the sounding pitch, the head is drawn at the written one")
func octaveShiftSoundingAndWritten() throws {
    let shifted = try score([dir("<octave-shift type=\"down\" size=\"8\"/>") + note("C", 6, dur: 4)])
    let plain = try score([note("C", 5, dur: 4)])
    #expect(Timeline(score: shifted).entries[0].notes.map(\.midi) == [84])
    #expect(Timeline(score: plain).entries[0].notes.map(\.midi) == [72])
    let a = shifted.layout(.default), b = plain.layout(.default)
    let ya = try #require(a.noteBoxes[NoteID(0)]).minY - a.systems[0].staves[0].top
    let yb = try #require(b.noteBoxes[NoteID(0)]).minY - b.systems[0].staves[0].top
    #expect(abs(ya - yb) < 1e-9, "C6 under 8va sits where C5 does")
}

@Test("pedal: start/stop pair, change adds a notch, resume and discontinue make a line without signs, signs default from line")
func pedalParse() throws {
    let s = try score([
        dir("<pedal type=\"start\" line=\"no\"/>") + note("C", 4) + dir("<pedal type=\"change\" line=\"no\"/>") + note("D", 4) + dir("<pedal type=\"stop\" line=\"no\"/>") + note("E", 4) + note("F", 4),
        dir("<pedal type=\"start\" line=\"yes\"/>") + note("C", 4, dur: 2) + dir("<pedal type=\"change\" line=\"yes\"/>") + note("D", 4, dur: 2) + dir("<pedal type=\"stop\" line=\"yes\" sign=\"yes\"/>"),
        dir("<pedal type=\"resume\" line=\"yes\" sign=\"yes\"/>") + note("C", 4, dur: 4) + dir("<pedal type=\"discontinue\" line=\"yes\" sign=\"no\"/>"),
    ])
    let p = s.parts[0].pedals
    #expect(p.count == 3)
    #expect(p[0].line == false && p[0].startSign && p[0].released && p[0].changes == [ScorePosition(measure: 0, onset: Rational(1))])
    #expect(p[0].end == ScorePosition(measure: 0, onset: Rational(2)))
    #expect(p[1].line && !p[1].startSign && p[1].released && p[1].changes.count == 1)
    #expect(p[2].line && p[2].startSign && !p[2].released, "a resume prints Ped. only when sign says so; discontinue gives no release")
}

@Test("dynamics, wedges and slurs: parsed with placement, offsets and numbers")
func marksParse() throws {
    let s = try score([
        dir("<dynamics><mf/></dynamics>", placement: "below") + dir("<dynamics><sf/><p/></dynamics>") + dir("<dynamics><other-dynamics>sfz</other-dynamics></dynamics>", placement: "above")
            + dir("<wedge type=\"crescendo\" number=\"1\"/>") + note("C", 4, notations: "<slur type=\"start\" number=\"2\" placement=\"above\"/>") + note("D", 4)
            + dir("<wedge type=\"stop\" number=\"1\"/>", offset: -1) + note("E", 4, notations: "<slur type=\"stop\" number=\"2\"/>") + note("F", 4),
    ])
    let p = s.parts[0]
    #expect(p.dynamics.map(\.text) == ["mf", "sfp", "sfz"])
    #expect(p.dynamics.map(\.above) == [false, false, true])
    #expect(p.wedges.count == 1)
    #expect(p.wedges[0].crescendo)
    // The stop is at quarter 2, moved back one quarter by its offset.
    #expect(p.wedges[0].end == ScorePosition(measure: 0, onset: Rational(1)))
    let slurs = p.measures[0].notes.flatMap(\.slurs)
    #expect(slurs == [SlurMark(kind: .start, number: 2, above: true), SlurMark(kind: .stop, number: 2, above: nil)])
}

// MARK: Layout

private func items(_ l: ScoreLayout, _ kind: LaidMark.Kind) -> [[LayoutItem]] {
    l.systems.flatMap { sys in sys.marks.filter { $0.kind == kind }.map { Array(sys.items[$0.items]) } }
}
private func glyphs(_ its: [LayoutItem]) -> [UInt32] { its.compactMap { if case .glyph(let c, _, _, _, _) = $0 { c } else { nil } } }

@Test("octave line: label, dashed line and a hook toward the staff; 8vb goes below")
func octaveLineLayout() throws {
    let s = try score([
        dir("<octave-shift type=\"down\" size=\"8\"/>", placement: "above") + four("C", 6) + dir("<octave-shift type=\"stop\" size=\"8\"/>"),
        dir("<octave-shift type=\"up\" size=\"15\"/>", placement: "below") + four("C", 2) + dir("<octave-shift type=\"stop\" size=\"15\"/>"),
    ])
    let l = s.layout(.singleLine)
    let sys = l.systems[0]
    let top = sys.staves[0].top
    let lines = items(l, .octaveLine)
    #expect(lines.count == 2)
    #expect(glyphs(lines[0]) == [Glyph.ottavaAlta.codepoint])
    #expect(glyphs(lines[1]) == [Glyph.quindicesimaBassaMb.codepoint])
    func ys(_ its: [LayoutItem]) -> [Double] { its.compactMap { if case .line(let a, _, _, _, _) = $0 { a.y } else { nil } } }
    #expect(ys(lines[0]).allSatisfy { $0 < top }, "8va is above the staff")
    #expect(ys(lines[1]).allSatisfy { $0 > top + 4 }, "8vb is below it")
    // The last item is the hook: vertical, toward the staff (down for 8va, up for 8vb).
    if case .line(let a, let b, _, _, _) = lines[0].last! { #expect(a.x == b.x && b.y > a.y) } else { Issue.record("no hook") }
    if case .line(let a, let b, _, _, _) = lines[1].last! { #expect(a.x == b.x && b.y < a.y) } else { Issue.record("no hook") }
    // The line ends near the last shifted note and starts at the first.
    let heads = (0..<4).compactMap { l.noteBoxes[NoteID($0)] }
    let xs = lines[0].compactMap { if case .line(let a, let b, _, _, _) = $0 { [a.x, b.x] } else { nil } }.flatMap { $0 }
    #expect(xs.max()! >= heads.map(\.maxX).max()! && xs.max()! <= heads.map(\.maxX).max()! + 1.5)
}

@Test("octave line: breaks across systems, the next one says (8va) again and has no hook at the break")
func octaveLineBreak() throws {
    let s = try score([dir("<octave-shift type=\"down\" size=\"8\"/>")] + (0..<10).map { _ in four("C", 6) } + [dir("<octave-shift type=\"stop\" size=\"8\"/>")])
    let l = s.layout(LayoutOptions(width: .fixed(60)))
    #expect(l.systems.count >= 3)
    let lines = items(l, .octaveLine)
    #expect(lines.count == l.systems.count)
    let first = glyphs(lines[0]), second = glyphs(lines[1])
    #expect(first == [Glyph.ottavaAlta.codepoint])
    #expect(second == [Glyph.octaveParensLeft.codepoint, Glyph.ottavaAlta.codepoint, Glyph.octaveParensRight.codepoint])
    func vertical(_ its: [LayoutItem]) -> Int { its.filter { if case .line(let a, let b, _, _, _) = $0 { a.x == b.x } else { false } }.count }
    #expect(vertical(lines[0]) == 0, "no hook where the line goes on")
}

@Test("pedal: Ped. and * go below the bass staff; a line has a hook at the release and a notch per change")
func pedalLayout() throws {
    let s = try score([
        dir("<pedal type=\"start\" line=\"no\"/>", staff: 2) + four("C", 4) + dir("<pedal type=\"stop\" line=\"no\"/>", staff: 2),
        dir("<pedal type=\"start\" line=\"yes\" sign=\"yes\"/>", staff: 2) + note("C", 4, dur: 2) + dir("<pedal type=\"change\" line=\"yes\"/>", staff: 2) + note("C", 4, dur: 2) + dir("<pedal type=\"stop\" line=\"yes\"/>", staff: 2),
    ], staves: 2)
    // Staff 2 needs notes of its own.
    let l = s.layout(.singleLine)
    let sys = l.systems[0]
    let bass = sys.staves[1].top
    let pedals = items(l, .pedal)
    #expect(pedals.count == 2)
    #expect(glyphs(pedals[0]) == [Glyph.keyboardPedalPed.codepoint, Glyph.keyboardPedalUp.codepoint])
    for it in pedals.flatMap({ $0 }) { #expect(it.bounds.minY > bass + 4, "below the bass staff") }
    // Line form: Ped. sign, then a stroked path with one notch (3 points) and a final hook.
    #expect(glyphs(pedals[1]) == [Glyph.keyboardPedalPed.codepoint])
    guard case .path(let els, let stroke, let fill, _, _) = pedals[1].last! else { Issue.record("no line"); return }
    #expect(stroke == EngravingDefaults.pedalLineThickness && !fill)
    let pts = els.compactMap { e -> CGPoint? in if case .line(let p) = e { p } else if case .move(let p) = e { p } else { nil } }
    let baseY = pts.first!.y
    #expect(pts.filter { $0.y < baseY - 0.5 }.count == 2, "one notch apex and the release hook")
    #expect(pts.last!.y < baseY, "ends with the hook up")
}

@Test("pedal: a bracket breaks across systems without a release hook at the break")
func pedalBreak() throws {
    let s = try score([dir("<pedal type=\"start\" line=\"yes\" sign=\"yes\"/>", staff: 2)] + (0..<8).map { _ in four("C", 4) + "" } + [dir("<pedal type=\"stop\" line=\"yes\"/>", staff: 2)], staves: 2)
    let l = s.layout(LayoutOptions(width: .fixed(50)))
    #expect(l.systems.count >= 2)
    let p = items(l, .pedal)
    #expect(p.count == l.systems.count)
    func hooks(_ its: [LayoutItem]) -> Int {
        guard case .path(let els, _, _, _, _)? = its.last else { return 0 }
        guard case .line(let end) = els.last!, case .line(let before) = els[els.count - 2] else { return 0 }
        return end.y < before.y ? 1 : 0
    }
    #expect(hooks(p[0]) == 0 && hooks(p.last!) == 1)
}

@Test("slurs: above or below by placement, else on the notehead side; one path per slur, from head to head")
func slurLayout() throws {
    let up = (0..<4).map { note("C", 5, extra: "<stem>up</stem>", notations: $0 == 0 ? "<slur type=\"start\"/>" : $0 == 3 ? "<slur type=\"stop\"/>" : "") }.joined()
    let down = (0..<4).map { note("C", 5, extra: "<stem>down</stem>", notations: $0 == 0 ? "<slur type=\"start\"/>" : $0 == 3 ? "<slur type=\"stop\"/>" : "") }.joined()
    let placed = (0..<4).map { note("C", 5, extra: "<stem>up</stem>", notations: $0 == 0 ? "<slur type=\"start\" placement=\"above\"/>" : $0 == 3 ? "<slur type=\"stop\"/>" : "") }.joined()
    let s = try score([up, down, placed])
    let l = s.layout(.singleLine)
    let slurs = items(l, .slur).map { $0[0] }
    #expect(slurs.count == 3)
    let top = l.systems[0].staves[0].top
    func apexAbove(_ it: LayoutItem) -> Bool {
        let b = it.bounds
        let head = (b.minY + b.maxY) / 2
        guard case .path(let els, _, _, _, _) = it, case .move(let p) = els[0] else { return false }
        return head < p.y - 0.01
    }
    #expect(!apexAbove(slurs[0]), "stems up: slur on the notehead side, below")
    #expect(apexAbove(slurs[1]), "stems down: above")
    #expect(apexAbove(slurs[2]), "placement above overrides")
    // The ends sit near the first and last head of their slur.
    for (k, it) in slurs.enumerated() {
        guard case .path(let els, _, _, _, _) = it, case .move(let p) = els[0] else { continue }
        let heads = (0..<4).map { l.noteBoxes[NoteID(k * 4 + $0)]! }
        #expect(abs(p.x - heads[0].midX) < 0.7 && abs(p.y - heads[0].midY) < (k == 2 ? 4.3 : 1.6),   // stem tip when the stem is on the slur's side
                "\(k) \(p) \(heads[0]) \(top)")
    }
}

@Test("slurs: a slur across a system break is two halves, each drawn in ink with no note id")
func slurBreak() throws {
    let measures = (0..<8).map { i in
        (0..<4).map { j in note("C", 5, extra: "<stem>down</stem>", notations: i == 0 && j == 0 ? "<slur type=\"start\"/>" : i == 7 && j == 3 ? "<slur type=\"stop\"/>" : "") }.joined()
    }
    let l = try score(measures).layout(LayoutOptions(width: .fixed(50)))
    #expect(l.systems.count >= 2)
    let s = items(l, .slur).map { $0[0] }
    #expect(s.count == l.systems.count)
    #expect(s.allSatisfy { $0.noteID == nil && $0.groupID == nil })
}

@Test("slurs: unmatched starts and stops are dropped, and a stop pairs by number")
func slurPairing() throws {
    let s = try score([
        note("C", 5, notations: "<slur type=\"start\" number=\"1\"/><slur type=\"start\" number=\"2\"/>") + note("D", 5, notations: "<slur type=\"stop\" number=\"1\"/>")
            + note("E", 5, notations: "<slur type=\"stop\" number=\"2\"/>") + note("F", 5, notations: "<slur type=\"stop\" number=\"3\"/><slur type=\"start\" number=\"4\"/>"),
    ])
    let sp = Engraving.pairSlurs(s, parts: [0])
    #expect(sp.map { [$0.start.value, $0.end.value] } == [[0, 1], [0, 2]])
}

@Test("dynamics: SMuFL glyphs below the staff, centred on the notehead of their onset; above when placed above")
func dynamicsLayout() throws {
    let s = try score([
        dir("<dynamics><mf/></dynamics>") + note("C", 5) + note("D", 5) + dir("<dynamics><p/></dynamics>", placement: "above") + note("E", 5) + dir("<dynamics><sfz/></dynamics>") + note("F", 5),
    ])
    let l = s.layout(.singleLine)
    let top = l.systems[0].staves[0].top
    let d = items(l, .dynamic).sorted { $0[0].bounds.minX < $1[0].bounds.minX }
    #expect(d.count == 3)
    #expect(glyphs(d[0]) == [Glyph.dynamicMF.codepoint])
    #expect(glyphs(d[2]) == [Glyph.dynamicSforzato.codepoint])
    #expect(glyphs(d[1]) == [Glyph.dynamicPiano.codepoint])
    for k in [0, 2] { #expect(d[k][0].bounds.minY > top + 4, "below") }
    #expect(d[1][0].bounds.maxY < top, "above")
    let heads = (0..<4).map { l.noteBoxes[NoteID($0)]! }
    for (k, n) in [(0, 0), (1, 2), (2, 3)] { #expect(abs(d[k][0].bounds.midX - heads[n].midX) < 0.7, "dynamic \(k) over note \(n)") }
}

@Test("hairpins: two strokes opening to the right (crescendo) or left, ending before a dynamic at the end; between the staves for the right hand")
func hairpinLayout() throws {
    let rh = four("C", 5)
    let lh = four("C", 3, staff: 2)
    let sc = try score([
        dir("<wedge type=\"crescendo\" number=\"1\"/>") + rh + "<backup><duration>4</duration></backup>" + lh,
        dir("<wedge type=\"stop\" number=\"1\"/>") + dir("<dynamics><f/></dynamics>") + rh + "<backup><duration>4</duration></backup>" + lh,
    ], staves: 2)
    let l = sc.layout(.singleLine)
    let sys = l.systems[0]
    let h = items(l, .hairpin)
    #expect(h.count == 1)
    guard case .line(let a1, let b1, _, _, _) = h[0][0], case .line(let a2, let b2, _, _, _) = h[0][1] else { Issue.record("two strokes"); return }
    #expect(a1.x == a2.x && a1.y == a2.y, "closed end at the start")
    #expect(abs(b1.y - b2.y) > 0.5, "open at the end")
    #expect(a1.y > sys.staves[0].top + 4 && b1.y < sys.staves[1].top, "between the staves")
    let f = try #require(items(l, .dynamic).first)
    #expect(max(b1.x, b2.x) < f[0].bounds.minX, "ends before the f")
}

@Test("hairpins: broken across systems, each half open at the break")
func hairpinBreak() throws {
    let s = try score([dir("<wedge type=\"diminuendo\" number=\"1\"/>")] + (0..<8).map { _ in four("C", 5) } + [dir("<wedge type=\"stop\" number=\"1\"/>")])
    let l = s.layout(LayoutOptions(width: .fixed(50)))
    #expect(l.systems.count >= 2)
    let h = items(l, .hairpin)
    #expect(h.count == l.systems.count)
    func spread(_ its: [LayoutItem], atEnd: Bool) -> Double {
        guard case .line(let a, let b, _, _, _) = its[0], case .line(let c, let d, _, _, _) = its[1] else { return -1 }
        return atEnd ? abs(b.y - d.y) : abs(a.y - c.y)
    }
    #expect(spread(h[0], atEnd: false) > 0.5, "a diminuendo starts open")
    #expect(spread(h[0], atEnd: true) > 0.1, "and is still open at the break")
    #expect(spread(h[1], atEnd: false) > 0.1)
    #expect(spread(h.last!, atEnd: true) < 1e-9, "closed at its end")
}

@Test("marks are laid out in line view and page view alike, and every mark has a staff")
func marksBothViews() throws {
    let s = try Score.load(data: fixture("complex/openscore/boulanger-parfois-je-suis-triste.mxl"))
    for o in [LayoutOptions.singleLine, LayoutOptions(width: .fixed(100))] {
        var opts = o
        opts.restrict(toPianoOf: s)
        let l = s.layout(opts)
        let kinds = Set(l.systems.flatMap(\.marks).map(\.kind))
        #expect(kinds.isSuperset(of: [.slur, .dynamic, .hairpin, .octaveLine, .pedal]))
        for sys in l.systems { for m in sys.marks { #expect(m.staffIndex < sys.staves.count && m.items.upperBound <= sys.items.count) } }
    }
}

// MARK: Clash-free on the OpenScore fixtures

/// The option sets the app and the CLI use: piano staves at two widths, the whole score, one long
/// line, and with fingering on.
private func optionSets(_ s: Score) -> [(String, LayoutOptions)] {
    var line = LayoutOptions.singleLine; line.restrict(toPianoOf: s)
    var finger = pianoOptions(s, width: 80); finger.showFingering = true
    return [("piano 80", pianoOptions(s, width: 80)), ("piano 100", pianoOptions(s, width: 100)),
            ("all parts 80", LayoutOptions(width: .fixed(80))), ("line", line), ("fingering", finger)]
}

@Test("notation marks never overlap notes, other marks or text, on every complex score and option set", arguments: openScore)
func marksClashFree(name: String) throws {
    let s = try Score.load(data: fixture("complex/openscore/\(name).mxl"))
    for (label, o) in optionSets(s) {
        let cs = markClashes(s.layout(o))
        #expect(cs.isEmpty, "\(name) \(label): \(cs.count)\n\(cs.prefix(8).map(\.description).joined(separator: "\n"))")
    }
}

@Test("slurs pair by voice and staff first, so two slurs of one number in two staves do not cross")
func slurPairingVoices() throws {
    // Staff 1 voice 1 and staff 2 voice 5 both run a slur number 1 from onset 0; the stops come in the other order.
    let s = try score([
        note("C", 5, notations: "<slur type=\"start\" number=\"1\"/>") + note("D", 5) + note("E", 5, notations: "<slur type=\"stop\" number=\"1\"/>") + note("F", 5)
            + "<backup><duration>4</duration></backup>"
            + "<note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><voice>5</voice><staff>2</staff><notations><slur type=\"start\" number=\"1\"/></notations></note>"
            + "<note><pitch><step>D</step><octave>3</octave></pitch><duration>1</duration><voice>5</voice><staff>2</staff><notations><slur type=\"stop\" number=\"1\"/></notations></note>"
            + "<note><pitch><step>E</step><octave>3</octave></pitch><duration>2</duration><voice>5</voice><staff>2</staff></note>",
    ], staves: 2)
    let sp = Engraving.pairSlurs(s, parts: [0])
    #expect(sp.count == 2 && sp.allSatisfy { $0.startStaff == $0.endStaff })
}

@Test("a slur on a grace note goes below, head to head")
func graceSlur() throws {
    let s = try score([
        "<note><grace/><pitch><step>D</step><octave>5</octave></pitch><voice>1</voice><staff>1</staff><notations><slur type=\"start\" placement=\"above\"/></notations></note>"
            + note("E", 5, dur: 4, notations: "<slur type=\"stop\"/>"),
    ])
    let l = s.layout(.singleLine)
    let slur = try #require(items(l, .slur).first?.first)
    guard case .path(let els, _, _, _, _) = slur, case .move(let p) = els[0] else { Issue.record("no slur"); return }
    let grace = try #require(l.noteBoxes[NoteID(0)])
    #expect(p.y > grace.midY, "starts under the head, not at the stem tip")
}

@Test("a hairpin or pedal that ends on the next system's downbeat ends on this one, with no stub on the next")
func endsOnDownbeat() throws {
    // Eight measures of four quarters fill systems of 2 or 3 measures; find the break and end the wedge on it.
    let plain = (0..<8).map { _ in four("C", 5) }
    let probe = try score(plain).layout(LayoutOptions(width: .fixed(50)))
    let brk = probe.systems[1].measureRange.lowerBound
    var ms = plain
    ms[0] = dir("<wedge type=\"crescendo\" number=\"1\"/>") + ms[0]
    ms[brk] = dir("<wedge type=\"stop\" number=\"1\"/>") + ms[brk]
    let l = try score(ms).layout(LayoutOptions(width: .fixed(50)))
    #expect(l.systems.count == probe.systems.count)
    let perSystem = l.systems.map { $0.marks.filter { $0.kind == .hairpin }.count }
    #expect(perSystem[0] == 1 && perSystem[1] == 0, "the wedge ends at the barline of system 1")
}

@Test("a pedal resume honours its sign, and without one starts with a hook")
func pedalResume() throws {
    let s = try score([
        dir("<pedal type=\"resume\" line=\"yes\" sign=\"yes\"/>", staff: 2) + four("C", 3, staff: 2) + dir("<pedal type=\"discontinue\" line=\"yes\"/>", staff: 2),
        dir("<pedal type=\"resume\" line=\"yes\"/>", staff: 2) + four("C", 3, staff: 2) + dir("<pedal type=\"stop\" line=\"yes\"/>", staff: 2),
    ], staves: 2)
    #expect(s.parts[0].pedals.map(\.startSign) == [true, false])
    let p = items(s.layout(.singleLine), .pedal)
    #expect(glyphs(p[0]) == [Glyph.keyboardPedalPed.codepoint] && glyphs(p[1]).isEmpty)
    guard case .path(let els, _, _, _, _) = p[1].last!, case .move(let a) = els[0], case .line(let b) = els[1] else { Issue.record("no hook"); return }
    #expect(a.x == b.x && a.y < b.y, "a hook up at the start")
}

@Test("octave lines skip the notes of a voice that lives on the other staff")
func octaveCrossStaff() throws {
    let s = try score([
        dir("<octave-shift type=\"down\" size=\"8\"/>") + note("C", 6) + note("D", 6)
            + "<note><pitch><step>E</step><octave>3</octave></pitch><duration>1</duration><voice>5</voice><staff>1</staff></note>"
            + note("F", 6) + "<backup><duration>4</duration></backup>"
            + (0..<4).map { _ in "<note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration><voice>5</voice><staff>2</staff></note>" }.joined(),
    ], staves: 2)
    let n = s.parts[0].measures[0].notes
    #expect(n.map(\.displayOctaves) == [-1, -1, 0, -1, 0, 0, 0, 0])
}

@Test("the mark clash check sees a dynamic moved onto a notehead")
func markClashCheckDetects() throws {
    let s = try score([dir("<dynamics><mf/></dynamics>") + four("C", 5)])
    var l = s.layout(.singleLine)
    #expect(markClashes(l).isEmpty)
    let box = try #require(l.noteBoxes[NoteID(0)])
    let m = try #require(l.systems[0].marks.first { $0.kind == .dynamic })
    l.systems[0].items[m.items.lowerBound] = .glyph(codepoint: Glyph.dynamicMF.codepoint, position: CGPoint(x: box.minX, y: box.midY + 0.3))
    #expect(!markClashes(l).isEmpty)
}

@Test("the OpenScore piano parts draw the expected number of each mark")
func marksCounts() throws {
    // Octave lines of the piano parts; pedal pieces; hairpins and dynamics of the piano parts.
    let b = try Score.load(data: fixture("complex/openscore/boulanger-parfois-je-suis-triste.mxl"))
    #expect(b.parts[1].octaveShifts.count == 8)
    #expect(b.parts[1].octaveShifts.filter { $0.octaves == 1 }.count == 1)
    let sc = try Score.load(data: fixture("complex/openscore/schumann-widmung.mxl"))
    #expect(sc.parts[1].pedals.count == 24)
    #expect(sc.parts[1].pedals.allSatisfy { !$0.line && $0.startSign && $0.released })
}
