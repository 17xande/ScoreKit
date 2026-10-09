import Foundation
import Testing
@testable import ScoreKit

private func load(_ name: String) throws -> Score { try Score.load(data: fixture(name)) }
private func edge(_ name: String) throws -> Score { try load("edge/\(name).musicxml") }
private func notes(_ s: Score, part: Int = 0) -> [Note] { s.parts[part].measures.flatMap(\.notes) }
private func tempos(_ s: Score) -> [Double] { s.parts.flatMap(\.measures).flatMap(\.directions).compactMap(\.quarterBPM) }

struct Starter: Sendable, CustomTestStringConvertible {
    let file: String, title: String, composer: String?, measures: Int, divisions: Int, tempo: Double
    var testDescription: String { file }
}

let starters = [
    Starter(file: "twinkle-twinkle", title: "", composer: nil, measures: 12, divisions: 0, tempo: 96),
    Starter(file: "ode-to-joy", title: "", composer: nil, measures: 16, divisions: 0, tempo: 100),
    Starter(file: "minuet-in-g", title: "Minuet in G major", composer: "Christian Petzold", measures: 16, divisions: 4, tempo: 108),
    Starter(file: "bach-prelude-in-c", title: "", composer: nil, measures: 4, divisions: 0, tempo: 66),
]

@Test("starters: one part, two staves, measure counts, tempo, unique ordered ids", arguments: starters)
func starterBasics(s: Starter) throws {
    let score = try load("\(s.file).musicxml")
    #expect(score.parts.count == 1)
    let part = score.parts[0]
    #expect(part.staves == 2)
    #expect(part.measures.count == s.measures)
    #expect(part.measures.map(\.index) == Array(0..<s.measures))
    #expect(part.measures.allSatisfy { $0.divisions > 0 })
    #expect(tempos(score).first == s.tempo)
    let ids = notes(score).map(\.id.value)
    #expect(ids == Array(0..<ids.count))
    if s.divisions > 0 { #expect(part.measures[0].divisions == s.divisions) }
    if s.composer != nil { #expect(score.composer == s.composer) }
    if !s.title.isEmpty { #expect(score.title == s.title) }
    #expect(score.title?.isEmpty == false)
}

@Test("starters: fingering counts")
func fingerings() throws {
    for f in ["ode-to-joy", "twinkle-twinkle", "minuet-in-g"] {
        #expect(notes(try load("\(f).musicxml")).filter { $0.fingering != nil }.count > 0, "\(f)")
    }
}

@Test("bach: voices 1, 5, 6 and 8 tie pairs")
func bach() throws {
    let s = try load("bach-prelude-in-c.musicxml")
    #expect(Set(notes(s).map(\.voice)).isSuperset(of: ["1", "5", "6"]))
    #expect(notes(s).filter(\.soundTieStart).count == 8)
    #expect(notes(s).filter(\.soundTieStop).count == 8)
}

@Test("minuet: repeats, key, time, F#, clefs, full bars")
func minuet() throws {
    let s = try load("minuet-in-g.musicxml")
    let ms = s.parts[0].measures
    let marks = ms.flatMap(\.barlines).compactMap(\.repeatMark?.direction)
    #expect(marks.contains(.forward))
    #expect(marks.contains(.backward))
    #expect(ms[0].keyChanges.map(\.key.fifths) == [1])
    #expect(ms[0].timeChanges.first?.time == TimeSignature(beats: 3, beatType: 4, symbol: nil))
    #expect(ms[0].clefChanges.map(\.clef.sign).sorted() == ["F", "G"])
    #expect(ms[0].clefChanges.first { $0.staff == 2 }?.clef.line == 4)
    #expect(notes(s).contains { $0.pitch?.alter == 1 && $0.pitch?.step == .F })
    #expect(notes(s).contains { $0.pitch?.semitoneAlter == 1 && $0.pitch?.midi == 66 })
    #expect(ms.dropFirst().allSatisfy { $0.keyChanges.isEmpty && $0.timeChanges.isEmpty })
    #expect(ms[0].duration == Rational(3))
}

@Test("pitch: midi and spelling")
func pitch() {
    #expect(Pitch(step: .C, octave: 4).midi == 60)
    #expect(Pitch(step: .B, alter: -1, octave: 3).midi == 58)
    #expect(Pitch(step: .A, alter: 0.5, octave: 4).midi == 70)
    #expect(Pitch(step: .F, alter: 1, octave: 4).spelling == "F#")
    #expect(Pitch(step: .E, alter: -1, octave: 4).spelling == "Eb")
}

@Test("rational: normalizes, orders, computes")
func rational() {
    #expect(Rational(2, 4) == Rational(1, 2))
    #expect(Rational(1, -2) == Rational(-1, 2))
    #expect(Rational(1, 3) + Rational(1, 6) == Rational(1, 2))
    #expect(Rational(1, 3) < Rational(1, 2))
    #expect(Rational(1, 2) * Rational(2, 3) == Rational(1, 3))
    #expect(Set([Rational(1, 2), Rational(2, 4)]).count == 1)
}

@Test("pickup: implicit measure 0 is short")
func pickup() throws {
    let ms = try edge("pickup").parts[0].measures
    #expect(ms[0].implicit)
    #expect(ms[0].number == "0")
    #expect(ms[0].index == 0)
    #expect(ms[0].duration == Rational(1))
    #expect(ms[1].duration == Rational(4))
    #expect(!ms[1].implicit)
}

@Test("chord: tones share an onset and don't advance")
func chord() throws {
    let ns = try edge("chord").parts[0].measures[0].notes
    let tones = ns.enumerated().filter { $0.element.isChordTone }
    #expect(tones.count == 2)
    for (i, n) in tones { #expect(n.onset == ns[i - 1].onset) }
    #expect(Set(ns.map(\.onset)).count == ns.count - tones.count)
    #expect(try edge("chord").parts[0].measures[0].duration == Rational(4))
}

@Test("voltas: ending numbers and types")
func voltas() throws {
    let endings = try edge("voltas").parts[0].measures.flatMap(\.barlines).compactMap(\.ending)
    #expect(endings.contains { $0.numbers == [1] && $0.kind == .start })
    #expect(endings.contains { $0.numbers == [1] && $0.kind == .stop })
    #expect(endings.contains { $0.numbers == [2] && $0.kind == .start })
    let ms = try edge("voltas").parts[0].measures
    let m = try #require(ms.first { $0.barlines.contains { $0.ending?.kind == .stop } })
    let right = m.barlines.first { $0.location == .right }
    #expect(right?.repeatMark?.direction == .backward)
    #expect(right?.onset == m.duration)
    #expect(endings.contains { $0.numbers == [2] && $0.kind == .discontinue })
}

@Test("repeat-times-3")
func repeatTimes() throws {
    let b = try edge("repeat-times-3").parts[0].measures.flatMap(\.barlines).compactMap(\.repeatMark)
    #expect(b.contains { $0.direction == .backward && $0.times == 3 })
    #expect(b.contains { $0.direction == .forward && $0.times == nil })
}

@Test("grace: duration 0, doesn't advance")
func grace() throws {
    let m = try edge("grace").parts[0].measures[0]
    let graces = m.notes.filter(\.isGrace)
    #expect(graces.count == 2)
    #expect(graces.allSatisfy { $0.duration == .zero })
    #expect(graces.first?.grace?.slash == true)
    #expect(graces.last?.grace?.slash == false)
    let first = m.notes[0], next = m.notes[1]
    #expect(first.onset == next.onset)
}

@Test("print-object=no is kept but flagged")
func printObject() throws {
    let ns = notes(try edge("print-object-no"))
    #expect(ns.filter { !$0.printObject }.count == 1)
    #expect(ns.filter(\.printObject).count == ns.count - 1)
}

@Test("forward leaves a gap in onsets")
func forward() throws {
    let m = try edge("forward").parts[0].measures
    #expect(m[0].notes.map(\.onset) == [Rational(0), Rational(3)])
    #expect(m[1].notes[0].onset == Rational(2))
}

@Test("tuplet: 1/3 quarter with time modification")
func tuplet() throws {
    let ns = try edge("tuplet").parts[0].measures[0].notes
    #expect(ns[0].duration == Rational(1, 3))
    #expect(ns[0].timeModification == TimeModification(actual: 3, normal: 2))
    #expect(ns[1].onset == Rational(1, 3))
    #expect(ns[3].onset == Rational(1))
    #expect(ns[3].timeModification == nil)
    #expect(try edge("tuplet").parts[0].measures[0].duration == Rational(4))
}

@Test("two-part-piano and voice-piano: parts and names")
func multiPart() throws {
    let two = try edge("two-part-piano")
    #expect(two.parts.map(\.name) == ["Piano RH", "Piano LH"])
    #expect(two.parts.map(\.id) == ["P1", "P2"])
    #expect(two.parts.allSatisfy { $0.measures.count == 2 })
    let vp = try edge("voice-piano")
    #expect(vp.parts.map(\.name) == ["Voice", "Piano"])
    // ids keep counting across parts
    let ids = vp.parts.flatMap { $0.measures.flatMap(\.notes) }.map(\.id.value)
    #expect(ids == Array(0..<ids.count))
}

@Test("tempo-change: tempo directions with onsets")
func tempoChange() throws {
    let s = try edge("tempo-change")
    let ds = s.parts[0].measures.flatMap(\.directions)
    #expect(ds.count == 3)
    #expect(ds.map(\.quarterBPM) == [120, 60, 90])
    #expect(ds[0].metronome?.beatUnit == .quarter)
    #expect(ds[0].soundTempo == 120)
    #expect(ds[2].soundTempo == nil)
    #expect(ds[0].placement == "above")
}

@Test("no-tempo has no directions; tie-chain has start/stop/both")
func noTempoAndTies() throws {
    #expect(tempos(try edge("no-tempo")).isEmpty)
    let ns = notes(try edge("tie-chain"))
    #expect(ns.contains { $0.soundTieStart && $0.soundTieStop })
    #expect(ns.allSatisfy { $0.soundTieStart == $0.drawnTieStart && $0.soundTieStop == $0.drawnTieStop })
}

@Test("backward-repeat-only and one-measure repeat parse")
func repeats() throws {
    let a = try edge("backward-repeat-only").parts[0].measures.flatMap(\.barlines).compactMap(\.repeatMark)
    #expect(a.map(\.direction) == [.backward])
    let b = try edge("repeat-one-measure").parts[0].measures.flatMap(\.barlines).compactMap(\.repeatMark)
    #expect(b.map(\.direction) == [.forward, .backward])
}

@Test(".mxl load equals the .musicxml load")
func mxlEqualsXML() throws {
    #expect(try load("minuet-in-g.mxl") == load("minuet-in-g.musicxml"))
    #expect(try load("ode-to-joy.mxl") == load("ode-to-joy.musicxml"))
    #expect(try load("edge/ode-to-joy.mxl") == load("ode-to-joy.musicxml"))
}

@Test("timewise scores are unsupported")
func timewise() {
    let xml = Data("<score-timewise version=\"4.0\"><part-list/></score-timewise>".utf8)
    #expect(throws: ScoreKitError.unsupported("score-timewise")) { try Score.parse(xml: xml) }
}

private func parseError(_ xml: String) -> ScoreKitError? {
    do { _ = try Score.parse(xml: Data(xml.utf8)); return nil } catch { return error as? ScoreKitError }
}

@Test("invalid scores throw with a line number")
func invalid() {
    #expect(parseError("<html/>") == .invalidScore(line: 1, detail: "root element is html"))
    let noList = parseError("<score-partwise>\n<part id=\"P1\"/></score-partwise>")
    guard case .invalidScore(let line, _)? = noList else { Issue.record("\(String(describing: noList))"); return }
    #expect(line == 1)
    let noDivs = parseError("""
        <score-partwise><part-list><score-part id="P1"><part-name>x</part-name></score-part></part-list>
        <part id="P1"><measure number="1">
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration></note>
        </measure></part></score-partwise>
        """)
    #expect(noDivs == nil)   // a missing <divisions> defaults to 1
    let badDivs = parseError("""
        <score-partwise><part-list><score-part id="P1"><part-name>x</part-name></score-part></part-list>
        <part id="P1"><measure number="1"><attributes><divisions>0</divisions></attributes>
        </measure></part></score-partwise>
        """)
    guard case .invalidScore(let l2, _)? = badDivs else { Issue.record("\(String(describing: badDivs))"); return }
    #expect(l2 == 2)
    #expect(parseError("not xml") != nil)
}

@Test("divisions change mid-score; empty measure takes the time signature; unknown elements ignored")
func carryOver() throws {
    let s = try Score.parse(xml: Data("""
        <score-partwise><part-list><score-part id="P1"><part-name>x</part-name></score-part></part-list>
        <part id="P1">
        <measure number="1"><attributes><divisions>1</divisions><time><beats>3</beats><beat-type>4</beat-type></time><wibble/></attributes>
        <frobnicate/><note><rest measure="yes"/></note></measure>
        <measure number="2"><attributes><divisions>2</divisions></attributes>
        <note><pitch><step>C</step><octave>4</octave></pitch><duration>3</duration></note>
        <backup><duration>3</duration></backup>
        <note><pitch><step>E</step><octave>4</octave></pitch><duration>2</duration></note>
        <note><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration></note></measure>
        <measure number="3"/>
        </part></score-partwise>
        """.utf8))
    let ms = s.parts[0].measures
    #expect(ms[0].duration == Rational(3))
    #expect(ms[0].notes[0].duration == Rational(3))
    #expect(ms[1].divisions == 2)
    #expect(ms[1].notes.map(\.onset) == [Rational(0), Rational(0), Rational(1)])
    #expect(ms[1].duration == Rational(2))
    #expect(ms[2].duration == Rational(3))
    #expect(ms[1].timeChanges.isEmpty)
    #expect(s.parts[0].staves == 1)
}

private func score(_ part: String, divisions: Int = 2) -> String {
    """
    <score-partwise><part-list><score-part id="P1"><part-name>x</part-name></score-part></part-list>
    <part id="P1">\(part)</part></score-partwise>
    """
}
private func note(_ dur: String) -> String {
    "<note><pitch><step>C</step><octave>4</octave></pitch><duration>\(dur)</duration></note>"
}

@Test("huge divisions and durations throw instead of trapping")
func overflow() {
    for part in [
        "<measure><attributes><divisions>4294967311</divisions></attributes>\(note("1"))</measure>",
        "<measure><attributes><divisions>2</divisions></attributes>\(note("2000000000"))</measure>",
        "<measure><attributes><divisions>2</divisions></attributes><forward><duration>1e12</duration></forward></measure>",
        "<measure><attributes><divisions>999983</divisions></attributes>\(note("1"))"
            + "<attributes><divisions>999979</divisions></attributes>\(note("1"))"
            + "<attributes><divisions>999961</divisions></attributes>\(note("1"))"
            + "<attributes><divisions>999959</divisions></attributes>\(note("1"))"
            + "<attributes><divisions>999953</divisions></attributes>\(note("1"))</measure>",
        "<measure><attributes><divisions>2</divisions><time><beats>100000</beats><beat-type>4</beat-type></time></attributes></measure>",
    ] {
        guard case .invalidScore? = parseError(score(part)) else { Issue.record("no throw: \(part.prefix(80))"); continue }
    }
}

@Test("Rational arithmetic is overflow-safe")
func rationalOverflow() {
    let big = Rational(Int.max, 3)
    #expect(big.adding(big) == nil)
    #expect(big.multiplied(by: Rational(5)) == nil)
    #expect(Rational(Int.min + 1, 1).subtracting(Rational(2)) == nil)
    #expect(Rational(1, Int.max) < Rational(1, Int.max - 1))
    #expect(Rational(Int.min + 1, 1) < Rational(0))
    #expect(Rational(1, 2) / Rational(1, 4) == Rational(2))
    #expect(Rational(Int.max, Int.max - 1).adding(Rational(0)) != nil)
}

@Test("negative durations throw; negative forward clamps; zero is kept")
func negativeDurations() throws {
    #expect(parseError(score("<measure><attributes><divisions>2</divisions></attributes>\(note("-2"))</measure>")) != nil)
    let s = try Score.parse(xml: Data(score("""
        <measure><attributes><divisions>2</divisions></attributes>\(note("2"))<forward><duration>-8</duration></forward>\(note("0"))</measure>
        """).utf8))
    let ns = s.parts[0].measures[0].notes
    #expect(ns[1].onset == .zero)
    #expect(ns[1].duration == .zero)
    #expect(ns[1].grace == nil)
}

@Test("a numberless key or time overwrites per-staff entries")
func staleKey() throws {
    func attrs(_ keys: String, _ times: String) -> String { "<attributes>\(keys)\(times)</attributes>" }
    func key(_ n: String?, _ f: Int) -> String { "<key\(n.map { " number=\"\($0)\"" } ?? "")><fifths>\(f)</fifths></key>" }
    func time(_ n: String?, _ b: Int) -> String { "<time\(n.map { " number=\"\($0)\"" } ?? "")><beats>\(b)</beats><beat-type>4</beat-type></time>" }
    let s = try Score.parse(xml: Data(score("""
        <measure number="1"><attributes><divisions>1</divisions>\(key("1", 1))\(key("2", 1))\(time("1", 3))\(time("2", 3))</attributes></measure>
        <measure number="2">\(attrs(key(nil, 2), time(nil, 4)))</measure>
        <measure number="3">\(attrs(key("1", 1), time("1", 3)))</measure>
        <measure number="4">\(attrs(key(nil, 1), time(nil, 3)))</measure>
        """).utf8))
    let ms = s.parts[0].measures
    #expect(ms[0].keyChanges.count == 2)
    #expect(ms[1].keyChanges.map(\.key.fifths) == [2])
    #expect(ms[2].keyChanges.map(\.key.fifths) == [1])
    #expect(ms[2].timeChanges.map(\.time.beats) == [3])
    #expect(ms[3].keyChanges.map(\.key.fifths) == [1])
    #expect(ms[1].duration == Rational(4))
}

@Test("decimal durations truncate like parseInt")
func decimalDurations() throws {
    let s = try Score.parse(xml: Data(score("""
        <measure><attributes><divisions>2.0</divisions></attributes>\(note("2.7"))<backup><duration>2.0</duration></backup>\(note("1.5"))</measure>
        """).utf8))
    let m = s.parts[0].measures[0]
    #expect(m.divisions == 2)
    #expect(m.notes[0].duration == Rational(1))
    #expect(m.notes[1].onset == .zero)
    #expect(m.notes[1].duration == Rational(1, 2))
}

@Test("direction offset, source, raw tempo fields")
func directionFields() throws {
    let s = try Score.parse(xml: Data(score("""
        <measure><attributes><divisions>4</divisions></attributes>\(note("4"))
        <direction placement="below"><direction-type><metronome><beat-unit>half</beat-unit><beat-unit-dot/><per-minute>c. 60</per-minute></metronome></direction-type><offset>2</offset><sound tempo="90.5"/></direction>
        <sound tempo="abc"/><sound tempo="70"/></measure>
        """).utf8))
    let ds = s.parts[0].measures[0].directions
    #expect(ds.count == 3)
    #expect(ds[0].source == .direction)
    #expect(ds[0].onset == Rational(1))
    #expect(ds[0].offset == Rational(1, 2))
    #expect(ds[0].soundTempo == 90.5)
    #expect(ds[0].soundTempoText == "90.5")
    #expect(ds[0].metronome?.perMinute == 60)
    #expect(ds[0].metronome?.perMinuteText == "c. 60")
    #expect(ds[0].metronome?.quarterBPM == Double(180))
    #expect(ds[1].source == .standaloneSound)
    #expect(ds[1].soundTempo == nil)
    #expect(ds[1].soundTempoText == "abc")
    #expect(ds[1].quarterBPM == nil)
    #expect(ds[2].source == .standaloneSound)
    #expect(ds[2].quarterBPM == 70)
}

@Test("ending keeps raw number, text and print-object")
func endingText() throws {
    let s = try Score.parse(xml: Data(score("""
        <measure><attributes><divisions>1</divisions></attributes>
        <barline location="left"><ending number="1, 2" type="start" print-object="no">1.-2.</ending></barline>\(note("4"))</measure>
        """).utf8))
    let e = try #require(s.parts[0].measures[0].barlines.first?.ending)
    #expect(e.numbers == [1, 2])
    #expect(e.rawNumber == "1, 2")
    #expect(e.text == "1.-2.")
    #expect(!e.printObject)
}

@Test("notes: drawn tie kinds, accidental marks, tuplet marks, cue size, clef flags, non-traditional key")
func noteExtras() throws {
    let s = try Score.parse(xml: Data(score("""
        <measure><attributes><divisions>1</divisions><key><key-step>F</key-step><key-alter>1</key-alter></key>
        <clef number=" 1 " after-barline="yes" print-object="no" additional="yes"><sign>G</sign></clef></attributes>
        <note><pitch><step>C</step><alter>1</alter><octave>4</octave></pitch><duration>1</duration><type size="cue">quarter</type>
        <accidental cautionary="yes" parentheses="yes">sharp</accidental>
        <notations><tied type="continue"/><tied type="let-ring"/><tuplet type="start" number="1" bracket="yes" show-number="both"/></notations></note>
        </measure>
        """).utf8))
    let m = s.parts[0].measures[0]
    let n = m.notes[0]
    #expect(n.cue)
    #expect(n.accidentalMarks == [.cautionary, .parentheses])
    #expect(n.drawnTieContinue && n.drawnTieLetRing && !n.drawnTieStart)
    #expect(n.tuplets == [TupletMark(kind: .start, number: 1, bracket: true, showNumber: "both")])
    #expect(m.keyChanges[0].key.nonTraditional && m.keyChanges[0].key.fifths == 0)
    let c = m.clefChanges[0]
    #expect(c.staff == 1 && c.clef.afterBarline && !c.clef.printObject && c.clef.additional && c.clef.line == 2)
}

@Test("measure-rest: whole-measure rest with its duration")
func measureRest() throws {
    let m = try edge("measure-rest").parts[0].measures[1]
    guard case .rest(let measureRest, _, _) = m.notes[0].kind else { Issue.record("not a rest"); return }
    #expect(measureRest)
    #expect(m.notes[0].duration == Rational(4))
    #expect(m.duration == Rational(4))
}

@Test("tempo-change-mid-measure: onsets and tempos")
func tempoMidMeasure() throws {
    let ds = try edge("tempo-change-mid-measure").parts[0].measures[0].directions
    #expect(ds.map(\.onset) == [Rational(0), Rational(2)])
    #expect(ds.map(\.quarterBPM) == [120, 60])
}

@Test("key-signature: fifths and accidentals")
func keySignature() throws {
    let ms = try edge("key-signature").parts[0].measures
    #expect(ms[0].keyChanges.map(\.key.fifths) == [-2])
    let ns = ms.flatMap(\.notes)
    #expect(ns.compactMap(\.accidental).contains("natural"))
    #expect(ns.compactMap(\.accidental).contains("sharp"))
    #expect(ns.compactMap(\.accidental).contains("flat"))
    let alters: [Double] = ns.compactMap { $0.pitch?.alter }
    #expect(alters.contains(-1))
    #expect(alters.contains(1))
    #expect(ms.dropFirst().allSatisfy { $0.keyChanges.isEmpty })
}
