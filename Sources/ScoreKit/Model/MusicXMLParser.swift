import Foundation

/// Turns a partwise MusicXML element tree into a `Score`.
struct MusicXMLParser {
    /// What carries over from measure to measure within one part.
    struct PartState {
        var divisions: Int?
        var keys: [Int: Key] = [:]      // by staff; 0 = all staves
        var times: [Int: TimeSignature] = [:]
        var clefs: [Int: Clef] = [:]
        var staves = 1
        /// Octave-shift, pedal, wedge and dynamics directions, paired up when the part ends.
        var marks: [RawMark] = []

        /// The value in effect for a staff: its own, else the one set for all staves.
        func effective<T>(_ table: [Int: T], _ staff: Int) -> T? { table[staff] ?? table[0] }
    }

    /// Largest accepted `<divisions>`, and largest `<duration>`/`<backup>`/`<forward>`
    /// (in divisions). Beyond these the exact arithmetic could overflow.
    private static let maxDivisions = 1_000_000
    private static let maxDuration = 1_000_000_000
    private static let maxBeats = 1000
    private static let maxBeatType = 1024

    private var nextID = 0

    struct PartInfo {
        var name: String
        var abbr: String?
        var instrumentName: String?
        var instrumentSound: String?
        var midiProgram: Int?
    }

    static func parse(root: XNode) throws -> Score {
        guard root.name == "score-partwise" else {
            if root.name == "score-timewise" { throw ScoreKitError.unsupported("score-timewise") }
            throw ScoreKitError.invalidScore(line: root.line, detail: "root element is \(root.name)")
        }
        guard let partList = root.child(named: "part-list") else {
            throw ScoreKitError.invalidScore(line: root.line, detail: "missing part-list")
        }
        var names: [String: PartInfo] = [:]
        for sp in partList.children(named: "score-part") {
            guard let id = sp.attribute("id") else { continue }
            let abbr = sp.child(named: "part-abbreviation")?.text
            let inst = sp.child(named: "score-instrument")
            names[id] = PartInfo(name: sp.child(named: "part-name")?.text ?? "", abbr: abbr?.isEmpty == false ? abbr : nil,
                                 instrumentName: nonEmpty(inst?.child(named: "instrument-name")?.text),
                                 instrumentSound: nonEmpty(inst?.child(named: "instrument-sound")?.text),
                                 midiProgram: sp.child(named: "midi-instrument")?.child(named: "midi-program")?.int)
        }
        var parser = MusicXMLParser()
        let parts = try root.children(named: "part").map { try parser.parsePart($0, names: names) }
        return Score(title: title(of: root), composer: composer(of: root), parts: parts)
    }

    // MARK: Metadata

    private static func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }

    private static func creditText(_ root: XNode, type: String) -> String? {
        for c in root.children(named: "credit")
        where c.children(named: "credit-type").contains(where: { $0.text == type }) {
            if let w = nonEmpty(c.child(named: "credit-words")?.text) { return w }
        }
        return nil
    }

    private static func title(of root: XNode) -> String? {
        nonEmpty(root.child("work", "work-title")?.text)
            ?? nonEmpty(root.child(named: "movement-title")?.text)
            ?? creditText(root, type: "title")
    }

    private static func composer(of root: XNode) -> String? {
        let creators = root.child(named: "identification")?.children(named: "creator") ?? []
        return nonEmpty(creators.first { $0.attribute("type") == "composer" }?.text)
            ?? creditText(root, type: "composer")
    }

    // MARK: Parts and measures

    private mutating func parsePart(_ node: XNode, names: [String: PartInfo]) throws -> Part {
        let id = node.attribute("id") ?? ""
        var state = PartState()
        var measures: [Measure] = []
        for (i, m) in node.children(named: "measure").enumerated() {
            measures.append(try parseMeasure(m, index: i, state: &state))
        }
        let usedStaff = measures.flatMap(\.notes).map(\.staff).max() ?? 1
        let info = names[id]
        var part = Part(id: id, name: info?.name ?? "", abbreviation: info?.abbr,
                    staves: max(state.staves, usedStaff), measures: measures,
                    instrumentName: info?.instrumentName, instrumentSound: info?.instrumentSound, midiProgram: info?.midiProgram)
        pairMarks(state.marks, into: &part)
        return part
    }

    private func bad(_ n: XNode, _ detail: String) -> ScoreKitError {
        .invalidScore(line: n.line, detail: detail)
    }

    /// A whole-number element value. Decimals truncate toward zero like OSMD's
    /// parseInt ("2.7" is 2); non-numbers give nil; magnitudes over `cap` throw.
    private func wholeNumber(_ n: XNode?, cap: Int) throws -> Int? {
        guard let n, let d = Double(n.text), d.isFinite else { return nil }
        guard abs(d) <= Double(cap) else { throw bad(n, "<\(n.name)> value out of range") }
        return Int(d.rounded(.towardZero))
    }

    /// Divisions-to-quarters; a part with no `<divisions>` yet counts as 1 per quarter.
    private func quarters(_ divs: Int, _ state: PartState) -> Rational {
        let d = state.divisions ?? 1   // no <divisions> yet: assume 1, as other readers do
        return Rational(divs, d)
    }

    private func add(_ a: Rational, _ b: Rational, at n: XNode) throws -> Rational {
        guard let r = a.adding(b) else { throw bad(n, "time arithmetic overflow") }
        return r
    }

    private mutating func parseMeasure(_ node: XNode, index: Int, state: inout PartState) throws -> Measure {
        var m = Measure(index: index, number: node.trimmedAttribute("number") ?? String(index + 1),
                        implicit: node.trimmedAttribute("implicit") == "yes",
                        duration: .zero, divisions: state.divisions ?? 1)
        var cursor = Rational.zero
        var furthest = Rational.zero
        var lastOnset = Rational.zero
        var rightMarks: [Int] = []       // jump marks on the right barline: onset is the measure's end
        var wantsBarLength: [Int] = []   // measure rests without a <duration>

        for el in node.children {
            switch el.name {
            case "attributes":
                try parseAttributes(el, onset: cursor, state: &state, into: &m)
            case "note":
                var note = try parseNote(el, state: state)
                note.onset = note.isChordTone ? lastOnset : cursor
                if note.grace == nil {
                    if let d = try wholeNumber(el.child(named: "duration"), cap: Self.maxDuration) {
                        guard d >= 0 else { throw bad(el, "negative <duration>") }
                        note.duration = quarters(d, state)
                    } else if case .rest(true, _, _) = note.kind {
                        wantsBarLength.append(m.notes.count)
                    }
                }
                let end = try add(note.onset, note.duration, at: el)
                if !note.isChordTone { lastOnset = note.onset }
                if !note.isChordTone && note.grace == nil { cursor = end }
                furthest = max(furthest, end)
                m.notes.append(note)
            case "backup", "forward":
                guard let d = try wholeNumber(el.child(named: "duration"), cap: Self.maxDuration) else { continue }
                // A negative value moves the other way; the cursor never goes below 0.
                let q = quarters(el.name == "backup" ? -d : d, state)
                cursor = max(.zero, try add(cursor, q, at: el))
                furthest = max(furthest, cursor)
            case "direction":
                state.marks += try rawMarks(el, at: ScorePosition(measure: index, onset: cursor), state: state)
                let sound = el.child(named: "sound")
                m.jumpMarks += Self.jumpMarks(in: el, sound: sound, onset: cursor)
                let text = sound?.attribute("tempo")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let metro = el.children(named: "direction-type").lazy.compactMap { dt in
                    dt.child(named: "metronome").map(Self.metronome)
                }.first
                let words = el.children(named: "direction-type").lazy.compactMap { dt -> String? in
                    let t = dt.child(named: "words")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.flatMap { $0.isEmpty ? nil : $0 }
                }.first
                if text != nil || metro != nil {
                    m.directions.append(TempoDirection(
                        source: .direction, onset: cursor, offset: try offset(el, state),
                        offsetSound: el.child(named: "offset")?.trimmedAttribute("sound") == "yes",
                        soundOffset: try sound.flatMap { try optionalOffset($0, state) },
                        placement: el.trimmedAttribute("placement"), staff: el.child(named: "staff")?.int,
                        soundTempo: text.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil },
                        soundTempoText: text, metronome: metro, words: words))
                }
            case "sound":
                m.jumpMarks += Self.jumpMarks(in: el, sound: el, onset: cursor)
                if let text = el.attribute("tempo")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    m.directions.append(TempoDirection(
                        source: .standaloneSound, onset: cursor, offset: .zero,
                        soundOffset: try optionalOffset(el, state),
                        placement: nil, staff: nil,
                        soundTempo: Double(text).flatMap { $0 > 0 ? $0 : nil },
                        soundTempoText: text, metronome: nil))
                }
            case "barline":
                let b = parseBarline(el, cursor: cursor)
                m.barlines.append(b)
                for mark in Self.barlineMarks(el, at: b.location == .right ? nil : b.onset) {
                    m.jumpMarks.append(mark)
                    if b.location == .right { rightMarks.append(m.jumpMarks.count - 1) }
                }
            default:
                break
            }
        }

        // An empty measure takes the bar length; so does a whole-measure rest with no duration.
        let barLength = state.effective(state.times, 1)?.quarters
        for i in wantsBarLength {
            m.notes[i].duration = barLength ?? .zero
            furthest = max(furthest, try add(m.notes[i].onset, m.notes[i].duration, at: node))
        }
        m.duration = furthest > .zero ? furthest : (barLength ?? .zero)
        for i in m.barlines.indices where m.barlines[i].location == .right { m.barlines[i].onset = m.duration }
        for i in rightMarks { m.jumpMarks[i].onset = m.duration }
        m.divisions = state.divisions ?? 1
        return m
    }

    /// A child `<offset>` in quarters, nil when absent.
    func optionalOffset(_ el: XNode, _ state: PartState) throws -> Rational? {
        guard let o = try wholeNumber(el.child(named: "offset"), cap: Self.maxDuration) else { return nil }
        return quarters(o, state)
    }

    /// A child `<offset>` (in divisions) as quarters.
    private func offset(_ el: XNode, _ state: PartState) throws -> Rational {
        guard let o = try wholeNumber(el.child(named: "offset"), cap: Self.maxDuration) else { return .zero }
        return quarters(o, state)
    }

    // MARK: Attributes

    private func parseAttributes(_ el: XNode, onset: Rational, state: inout PartState, into m: inout Measure) throws {
        if let d = el.child(named: "divisions") {
            guard let v = try wholeNumber(d, cap: Self.maxDivisions), v > 0 else { throw bad(d, "invalid <divisions>") }
            state.divisions = v
        }
        if let s = el.child(named: "staves")?.int, s > 0 {
            state.staves = max(state.staves, s)
            m.staves = s
        }
        for k in el.children(named: "key") {
            let staff = k.trimmedAttribute("number").flatMap { Int($0) }
            let fifths = k.child(named: "fifths")?.int.map { min(max($0, -14), 14) }   // theoretical keys stop at 14
            let key = Key(fifths: fifths ?? 0, mode: Self.nonEmpty(k.child(named: "mode")?.text),
                          nonTraditional: fifths == nil && k.child(named: "key-step") != nil)
            if state.effective(state.keys, staff ?? 0) != key || (staff == nil && state.keys.values.contains { $0 != key }) {
                m.keyChanges.append(KeyChange(onset: onset, staff: staff, key: key))
            }
            Self.set(&state.keys, staff, key)
        }
        for t in el.children(named: "time") {
            guard let beatsText = t.child(named: "beats")?.text,
                  let beatType = t.child(named: "beat-type")?.int, beatType > 0 else { continue }
            let beats = beatsText.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.reduce(0, +)
            guard beats > 0 else { continue }
            guard beats <= Self.maxBeats, beatType <= Self.maxBeatType else { throw bad(t, "unreasonable time signature") }
            let symbol: TimeSignature.Symbol? = switch t.trimmedAttribute("symbol") {
            case "common": .common
            case "cut": .cut
            default: nil
            }
            let staff = t.trimmedAttribute("number").flatMap { Int($0) }
            let ts = TimeSignature(beats: beats, beatType: beatType, symbol: symbol)
            if state.effective(state.times, staff ?? 0) != ts || (staff == nil && state.times.values.contains { $0 != ts }) {
                m.timeChanges.append(TimeChange(onset: onset, staff: staff, time: ts))
            }
            Self.set(&state.times, staff, ts)
        }
        for c in el.children(named: "clef") {
            guard let sign = Self.nonEmpty(c.child(named: "sign")?.text) else { continue }
            let staff = c.trimmedAttribute("number").flatMap { Int($0) } ?? 1
            let defaultLine: Int? = ["G": 2, "F": 4, "C": 3][sign]
            let clef = Clef(sign: sign, line: c.child(named: "line")?.int ?? defaultLine,
                            octaveChange: c.child(named: "clef-octave-change")?.int ?? 0,
                            afterBarline: c.trimmedAttribute("after-barline") == "yes",
                            printObject: c.trimmedAttribute("print-object") != "no",
                            additional: c.trimmedAttribute("additional") == "yes")
            if state.clefs[staff] != clef {
                state.clefs[staff] = clef
                m.clefChanges.append(ClefChange(onset: onset, staff: staff, clef: clef))
            }
        }
    }

    /// Record a key/time: an un-numbered one replaces every per-staff entry.
    private static func set<T>(_ table: inout [Int: T], _ staff: Int?, _ value: T) {
        if let staff { table[staff] = value } else { table = [0: value] }
    }

    // MARK: Directions and barlines

    private static func metronome(_ n: XNode) -> Metronome {
        let text = n.child(named: "per-minute")?.text
        // Tolerate "c. 120" and "120-132": take the first number.
        let digits = text?.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
        let bpm = digits.flatMap { Double($0) }
        return Metronome(beatUnit: n.child(named: "beat-unit").flatMap { NoteValue(xml: $0.text) },
                         dots: n.children(named: "beat-unit-dot").count,
                         perMinute: bpm.flatMap { $0 > 0 ? $0 : nil }, perMinuteText: text)
    }

    /// Jump marks of a `<direction>` (`el`, with its `<sound>`) or of a bare `<sound>`.
    private static func jumpMarks(in el: XNode, sound: XNode?, onset: Rational) -> [JumpMark] {
        var out: [JumpMark] = []
        if let sound {
            let table: [(String, JumpMark.Kind)] = [("dacapo", .dacapo), ("dalsegno", .dalsegno), ("segno", .segno),
                                                    ("coda", .coda), ("tocoda", .toCoda), ("fine", .fine)]
            for (attr, kind) in table {
                guard let v = sound.trimmedAttribute(attr), !v.isEmpty, v != "no" else { continue }
                let flag = kind == .dacapo || kind == .fine
                out.append(JumpMark(kind: kind, id: flag ? nil : v, onset: onset, source: .sound))
            }
        }
        if el.name == "direction" {
            for dt in el.children(named: "direction-type") {
                if dt.child(named: "segno") != nil { out.append(JumpMark(kind: .segno, id: nil, onset: onset, source: .directionType)) }
                if dt.child(named: "coda") != nil { out.append(JumpMark(kind: .coda, id: nil, onset: onset, source: .directionType)) }
            }
        }
        return out
    }

    /// `segno`/`coda` attributes (named ids) and child elements (unnamed) of a `<barline>`.
    /// `at` is nil for a right barline (the caller patches in the measure's end).
    private static func barlineMarks(_ el: XNode, at onset: Rational?) -> [JumpMark] {
        var out: [JumpMark] = []
        for (name, kind) in [("segno", JumpMark.Kind.segno), ("coda", .coda)] {
            if let v = el.trimmedAttribute(name), !v.isEmpty {
                out.append(JumpMark(kind: kind, id: v, onset: onset ?? .zero, source: .barline))
            }
            if el.child(named: name) != nil {
                out.append(JumpMark(kind: kind, id: nil, onset: onset ?? .zero, source: .barline))
            }
        }
        return out
    }

    private func parseBarline(_ el: XNode, cursor: Rational) -> Barline {
        let location: Barline.Location = switch el.trimmedAttribute("location") {
        case "left": .left
        case "middle": .middle
        default: .right
        }
        var b = Barline(location: location, onset: location == .middle ? cursor : .zero,
                        style: Self.nonEmpty(el.child(named: "bar-style")?.text))
        if let r = el.child(named: "repeat") {
            switch r.trimmedAttribute("direction") {
            case "forward": b.repeatMark = Repeat(direction: .forward, times: nil)
            case "backward": b.repeatMark = Repeat(direction: .backward, times: r.trimmedAttribute("times").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            default: break
            }
        }
        if let e = el.child(named: "ending") {
            let kind: Ending.Kind? = switch e.trimmedAttribute("type") {
            case "start": .start
            case "stop": .stop
            case "discontinue": .discontinue
            default: nil
            }
            if let kind {
                let raw = e.attribute("number") ?? ""
                b.ending = Ending(numbers: Self.endingNumbers(raw), rawNumber: raw, text: e.text,
                                  printObject: e.trimmedAttribute("print-object") != "no", kind: kind)
            }
        }
        return b
    }

    /// "1", "1, 2" and "1-3" to [1], [1, 2], [1, 2, 3]; junk is dropped.
    private static func endingNumbers(_ s: String) -> [Int] {
        var out: [Int] = []
        for part in s.split(separator: ",") {
            // "1." (a label with its full stop) counts as 1.
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 100 { out += Array(bounds[0]...bounds[1]) }
            else if bounds.count == 1 { out.append(bounds[0]) }
        }
        return out
    }

    // MARK: Notes

    /// Everything but the onset and the (divisions-based) duration, which the measure loop fills in.
    private mutating func parseNote(_ el: XNode, state: PartState) throws -> Note {
        let kind: Note.Kind
        if let r = el.child(named: "rest") {
            kind = .rest(measureRest: r.trimmedAttribute("measure") == "yes",
                         displayStep: r.child(named: "display-step").flatMap { Step(rawValue: $0.text) },
                         displayOctave: r.child(named: "display-octave")?.int)
        } else if let p = el.child(named: "pitch") {
            guard let step = p.child(named: "step").flatMap({ Step(rawValue: $0.text) }),
                  let octave = p.child(named: "octave")?.int else { throw bad(p, "invalid <pitch>") }
            kind = .pitched(Pitch(step: step, alter: p.child(named: "alter")?.double ?? 0, octave: octave))
        } else if let u = el.child(named: "unpitched") {
            kind = .unpitched(displayStep: u.child(named: "display-step").flatMap { Step(rawValue: $0.text) },
                              displayOctave: u.child(named: "display-octave")?.int)
        } else {
            throw bad(el, "note without pitch, rest or unpitched")
        }
        var n = Note(id: NoteID(nextID), kind: kind, onset: .zero, duration: .zero)
        nextID += 1

        n.noteValue = el.child(named: "type").flatMap { NoteValue(xml: $0.text) }
        n.dots = el.children(named: "dot").count
        n.voice = Self.nonEmpty(el.child(named: "voice")?.text) ?? "1"
        n.staff = el.child(named: "staff")?.int ?? 1
        n.isChordTone = el.child(named: "chord") != nil
        if let g = el.child(named: "grace") { n.grace = Grace(slash: g.trimmedAttribute("slash") == "yes") }
        n.cue = el.child(named: "cue") != nil || el.child(named: "type")?.trimmedAttribute("size") == "cue"
        n.printObject = el.trimmedAttribute("print-object") != "no"
        n.noHead = el.child(named: "notehead")?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "none"
        for t in el.children(named: "tie") {
            switch t.trimmedAttribute("type") {
            case "start": n.soundTieStart = true
            case "stop": n.soundTieStop = true
            default: break
            }
        }
        for notations in el.children(named: "notations") {
            for t in notations.children(named: "tied") {
                switch t.trimmedAttribute("type") {
                case "start": n.drawnTieStart = true
                case "stop": n.drawnTieStop = true
                case "continue": n.drawnTieContinue = true
                case "let-ring": n.drawnTieLetRing = true
                default: break
                }
            }
            for t in notations.children(named: "slur") {
                let kind: SlurMark.Kind? = switch t.trimmedAttribute("type") {
                case "start": .start
                case "stop": .stop
                case "continue": .continue
                default: nil
                }
                guard let kind else { continue }
                let side = t.trimmedAttribute("placement") ?? t.trimmedAttribute("orientation")
                n.slurs.append(SlurMark(kind: kind, number: t.trimmedAttribute("number").flatMap { Int($0) } ?? 1,
                                        above: side.flatMap { ["above": true, "over": true, "below": false, "under": false][$0] }))
            }
            for t in notations.children(named: "tuplet") {
                let kind: TupletMark.Kind? = switch t.trimmedAttribute("type") {
                case "start": .start
                case "stop": .stop
                default: nil
                }
                guard let kind else { continue }
                n.tuplets.append(TupletMark(kind: kind, number: t.trimmedAttribute("number").flatMap { Int($0) },
                                            bracket: t.trimmedAttribute("bracket").map { $0 == "yes" },
                                            showNumber: t.trimmedAttribute("show-number")))
            }
            if n.fingering == nil {
                for f in notations.child(named: "technical")?.children(named: "fingering") ?? [] where !f.text.isEmpty {
                    n.fingering = f.text
                    n.fingeringPlacement = f.trimmedAttribute("placement")
                    break
                }
            }
        }
        if let a = el.child(named: "accidental") {
            n.accidental = Self.nonEmpty(a.text)
            for (attr, mark) in [("cautionary", AccidentalMarks.cautionary), ("editorial", .editorial),
                                 ("parentheses", .parentheses), ("bracket", .bracket)]
            where a.trimmedAttribute(attr) == "yes" { n.accidentalMarks.insert(mark) }
        }
        n.stem = el.child(named: "stem").flatMap { Stem(rawValue: $0.text) }
        for b in el.children(named: "beam") {
            let value: BeamValue? = switch b.text {
            case "begin": .begin
            case "continue": .continue
            case "end": .end
            case "forward hook": .forwardHook
            case "backward hook": .backwardHook
            default: nil
            }
            if let value { n.beams.append(Beam(number: b.trimmedAttribute("number").flatMap { Int($0) } ?? 1, value: value)) }
        }
        if let tm = el.child(named: "time-modification"),
           let a = tm.child(named: "actual-notes")?.int, let nn = tm.child(named: "normal-notes")?.int, a > 0, nn > 0 {
            n.timeModification = TimeModification(actual: a, normal: nn)
        }
        return n
    }
}
