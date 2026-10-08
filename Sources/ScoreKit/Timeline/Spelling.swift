/// A pitch spelled on a letter: the accidental and octave follow the letter, not
/// the sounding pitch (B sharp 3 sounds as C4; C flat 4 as B3).
public struct Spelled: Sendable, Hashable {
    public var letter: Step
    /// Semitones from the natural letter (-2...2 in practice).
    public var acc: Int
    public var octave: Int

    public init(letter: Step, acc: Int, octave: Int) {
        self.letter = letter
        self.acc = acc
        self.octave = octave
    }

    /// Spell `midi` on `letter` (the web app's `spell`): the accidental is the
    /// smallest signed distance from the natural letter, within a tritone.
    public init(midi: Int, letter: Step) {
        func mod(_ a: Int, _ m: Int) -> Int { ((a % m) + m) % m }
        var acc = mod(midi - letter.semitone, 12)
        if acc > 6 { acc -= 12 }
        // Floor division, as Math.floor.
        let d = midi - acc
        let octave = (d >= 0 ? d / 12 : -((-d + 11) / 12)) - 1
        self.init(letter: letter, acc: acc, octave: octave)
    }
}
