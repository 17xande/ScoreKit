import Foundation

/// How a note joins a tie chain (only `<notations><tied>` counts, as in OSMD).
public enum TimelineTie: String, Sendable, Hashable {
    case none, start, `continue`
}

/// A note sounding at a timeline position.
public struct TimelineNote: Sendable, Hashable {
    public var id: NoteID
    /// Index into `Score.parts`.
    public var partIndex: Int
    /// 0-based staff within the part (the part's first staff is 0).
    public var staffInPart: Int
    public var voice: String
    public var midi: Int
    public var spelled: Spelled
    public var tie: TimelineTie
    /// For a tie start the whole chain's length, else the note's own; in quarters.
    public var quarters: Double
    public var fingering: String?

    public var step: Step { spelled.letter }
}

/// One playback position: every part's onset at this moment.
public struct TimelineEntry: Sendable, Hashable {
    /// 0-based index of the measure in the score.
    public var measureIndex: Int
    /// The web app's `measure`: `measureIndex + 1` (not the printed number).
    public var measure: Int { measureIndex + 1 }
    /// Index into `Unroll.measures` of the played measure this entry belongs to.
    public var playedMeasureIndex: Int
    /// Counts passes over measures: rises when the measure changes or the position
    /// within the measure does not advance.
    public var occurrence: Int
    /// Quarters since the start of playback, repeats played out.
    public var beatQuarters: Rational
    public var beat: Double { beatQuarters.double }
    /// Quarters into the measure.
    public var position: Rational
    public var bpm: Double
    /// The sounding notes of every part (rests, grace notes and hidden notes excluded).
    /// Empty for a rest-only position.
    public var notes: [TimelineNote]
}

/// The playback timeline of a score: repeats unrolled, ties merged, tempo applied.
///
/// This mirrors the web app's OSMD walk. Every visible position of any part gives
/// an entry, rests and parts nobody plays included (such positions have no notes).
/// Positions that are only invisible (`print-object="no"`, `<notehead>none`, `<forward>`) are skipped;
/// grace notes and zero-duration notes are not reported.
///
/// Ties follow OSMD's reader (open ties are kept per staff, matched by letter and
/// octave before pitch, so they cross voices and enharmonics; a tie that doesn't
/// reach its measure's end is dropped), but are resolved over the *played* order:
/// a tie out of a measure joins only the measure played next, so a tie before `:|`
/// does not claim a note after a volta, and a tie into ending 2 continues from the
/// measure before ending 1. OSMD resolves them in score order.
public struct Timeline: Sendable {
    public let entries: [TimelineEntry]
    public let unroll: Unroll
    public let tempoMap: TempoMap

    private let indices: [NoteID: [Int]]

    /// Total length in quarters.
    public var length: Rational { unroll.length }

    /// Indices into `entries` of the entries holding this note (one per time it is
    /// played; several when a repeat plays it again); empty if it never sounds.
    public func entryIndices(for id: NoteID) -> [Int] { indices[id] ?? [] }

    private struct Slot {
        var position: Rational
        var notes: [TimelineNote]
    }

    public init(score: Score) {
        let unroll = Unroll(score: score)
        let tempoMap = TempoMap(score: score)
        self.unroll = unroll
        self.tempoMap = tempoMap
        let slots = Self.slots(score)
        let ties = Self.resolveTies(score, unroll)

        var entries: [TimelineEntry] = []
        var bpm = TempoMap.defaultBPM
        var occurrence = 0
        var prevMeasure = -1
        var prevPosition: Rational?
        var carried: [TempoEvent] = []
        for (k, pm) in unroll.measures.enumerated() {
            var events = carried.map { TempoEvent(measureIndex: pm.index, position: .zero, bpm: $0.bpm) }
            if pm.index < tempoMap.events.count { events += tempoMap.events[pm.index] }
            var next = 0
            if pm.index < slots.count {
                for slot in slots[pm.index] where pm.plays(slot.position) {
                    while next < events.count, events[next].position <= slot.position {
                        bpm = events[next].bpm
                        next += 1
                    }
                    if pm.index != prevMeasure || prevPosition.map({ slot.position <= $0 }) ?? false { occurrence += 1 }
                    prevMeasure = pm.index
                    prevPosition = slot.position
                    let notes = slot.notes.map { n -> TimelineNote in
                        var n = n
                        if let t = ties[TieInstance(played: k, note: n.id)] {
                            n.tie = t.start ? .start : .continue
                            if t.start { n.quarters = t.total.double }
                        }
                        return n
                    }
                    entries.append(TimelineEntry(measureIndex: pm.index, playedMeasureIndex: k, occurrence: occurrence,
                                                 beatQuarters: pm.start + slot.position - pm.from, position: slot.position,
                                                 bpm: bpm, notes: notes))
                }
            }
            // A tempo after the measure's last position takes effect at the next one.
            carried = Array(events[next...])
        }
        self.entries = entries
        var indices: [NoteID: [Int]] = [:]
        for (i, e) in entries.enumerated() { for n in e.notes { indices[n.id, default: []].append(i) } }
        self.indices = indices
    }

    // MARK: Positions

    /// The visible positions of each measure index, with their notes (ties not yet resolved).
    private static func slots(_ score: Score) -> [[Slot]] {
        let n = score.parts.map(\.measures.count).max() ?? 0
        var byMeasure = [[Rational: (visible: Bool, notes: [TimelineNote])]](repeating: [:], count: n)
        for (pi, part) in score.parts.enumerated() {
            for m in part.measures where m.index < n {
                for note in m.notes where !note.isGrace && note.duration > .zero {
                    var slot = byMeasure[m.index][note.onset] ?? (false, [])
                    if note.printObject, !note.noHead {
                        slot.visible = true
                        if let pitch = note.pitch {
                            let midi = pitch.midi
                            slot.notes.append(TimelineNote(
                                id: note.id, partIndex: pi, staffInPart: max(0, note.staff - 1), voice: note.voice,
                                midi: midi, spelled: Spelled(midi: midi, letter: pitch.step), tie: .none,
                                quarters: note.duration.double, fingering: note.fingering))
                        }
                    }
                    byMeasure[m.index][note.onset] = slot
                }
            }
        }
        return byMeasure.map { dict in
            dict.filter { $0.value.visible }.map { Slot(position: $0.key, notes: $0.value.notes) }
                .sorted { $0.position < $1.position }
        }
    }

    // MARK: Ties

    private struct TieInstance: Hashable {
        var played: Int
        var note: NoteID
    }
    private struct Resolved {
        var start: Bool
        var total: Rational
    }
    private struct Chain {
        var first: TieInstance
        var total: Rational
        var touched: Int
        var pitch: Pitch
    }
    private struct StaffKey: Hashable {
        var part: Int
        var staff: Int
    }

    /// OSMD's tie reader (`VoiceGenerator.addTie`, `findCurrentNoteInTieDict`)
    /// run over the played measures.
    private static func resolveTies(_ score: Score, _ unroll: Unroll) -> [TieInstance: Resolved] {
        var chains: [Chain] = []
        var open: [StaffKey: [Int: Int]] = [:]   // staff -> tie number -> chain
        var chainOf: [TieInstance: Int] = [:]

        func find(_ note: Note, _ pitch: Pitch, in dict: [Int: Int]) -> Int? {
            let ordered = dict.keys.sorted()
            if let n = ordered.first(where: { num in
                let p = chains[dict[num]!].pitch
                return p.step == pitch.step && p.octave == pitch.octave
            }) { return n }
            return ordered.first { chains[dict[$0]!].pitch.midi == pitch.midi }
        }

        for (k, pm) in unroll.measures.enumerated() {
            for (pi, part) in score.parts.enumerated() where pm.index < part.measures.count {
                let measure = part.measures[pm.index]
                // A tied grace note opens a chain too (OSMD pairs it): the main note it ties into
                // is then a `continue`, already sounding, and the chain's length stays the main notes'.
                // In time order, not document order: a later voice's tie start may precede, in time,
                // an earlier voice's stop (Stanford m1: voice 2 holds E-flat/G into voice 1's chord).
                let inTime = measure.notes.enumerated().sorted { ($0.element.onset, $0.offset) < ($1.element.onset, $1.offset) }.map(\.element)
                for note in inTime where (note.isGrace || note.duration > .zero) && pm.plays(note.onset) {
                    guard let pitch = note.pitch else { continue }
                    let duration = note.isGrace ? Rational.zero : note.duration
                    let stops = note.drawnTieStop || note.drawnTieContinue
                    let starts = note.drawnTieStart || note.drawnTieContinue
                    guard stops || starts else { continue }
                    let key = StaffKey(part: pi, staff: note.staff)
                    let inst = TieInstance(played: k, note: note.id)
                    let dict = open[key] ?? [:]
                    if stops && starts {
                        if let num = find(note, pitch, in: dict) {
                            let c = dict[num]!
                            chainOf[inst] = c
                            chains[c].total += duration
                            chains[c].touched = k
                        }
                    } else if starts {
                        var num = 1
                        while dict[num] != nil { num += 1 }
                        chains.append(Chain(first: inst, total: duration, touched: k, pitch: pitch))
                        chainOf[inst] = chains.count - 1
                        open[key, default: [:]][num] = chains.count - 1
                    } else if let num = find(note, pitch, in: dict) {
                        let c = dict[num]!
                        chainOf[inst] = c
                        chains[c].total += duration
                        open[key]![num] = nil
                    }
                }
                // End of the measure: a tie the measure just played didn't start, continue or close
                // is abandoned. (OSMD's own checkOpenTies is never called in 2.1.3, so it keeps
                // such a tie open for ever; the tie-cross-voice fixture shows an abandoned start
                // still joining a stop a measure later, which this rule allows too.)
                for (key, dict) in open where key.part == pi {
                    for (num, c) in dict where chains[c].touched < k { open[key]![num] = nil }
                }
            }
        }
        var out: [TieInstance: Resolved] = [:]
        for (inst, c) in chainOf {
            out[inst] = Resolved(start: chains[c].first == inst, total: chains[c].total)
        }
        return out
    }
}
