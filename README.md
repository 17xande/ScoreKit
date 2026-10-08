# ScoreKit

A small, focused native Swift library that takes a MusicXML score (`.musicxml`
or compressed `.mxl`) and turns it into:

1. a **model** (parts, measures, notes),
2. a **playback timeline** (repeats unrolled, ties merged, tempo map),
3. an **engraving layout** (systems, glyph positions, per-note boxes, cursor
   spots and hit-testing), and
4. a **SwiftUI renderer** for it.

It exists for piano practice apps that need to show sheet music, follow a
cursor along it, colour notes as they are played and seek by tapping. It is
not a port of OpenSheetMusicDisplay.

## Products

- `ScoreKit`: core. Foundation (plus FoundationXML on Linux) and well-established
  packages only (currently [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
  for `.mxl` archives); builds and tests on Linux with `swift test`.
- `ScoreKitUI`: SwiftUI/CoreText renderer. Compiled only where SwiftUI exists.

Requires Swift 6 (swift-tools 6.0); iOS 17 / macOS 14.

## Scope

- Partwise MusicXML and `.mxl`, with multiple parts and grand staff.
- Timeline semantics for practice: unrolled repeats and voltas, merged ties,
  tempo changes, rests/grace/hidden notes skipped.
- Engraving: clefs, key/time signatures (and changes), noteheads, stems, flags,
  beams, accidentals, rests, dots, ledger lines, chords, two voices per staff,
  ties, barlines, repeats, voltas, brace, fingering, measure numbers, tempo
  marks, and a single-line mode.

## Non-goals

Slurs, dynamics, articulations, lyrics, tuplet brackets (timing is still
correct), drawn grace notes, cross-staff beams, 8va lines, D.C./D.S. jumps,
timewise scores, editing, MIDI/audio output, and pixel parity with any other
renderer.

## Status

Under construction: file reading (.mxl via ZIPFoundation, XML tree) is in place; model,
timeline and layout follow.

## Test fixtures

`Scripts/make-mxl.sh` regenerates the `.mxl` fixtures in
`Tests/ScoreKitTests/Fixtures` from the `.musicxml` files there. The generated
files are committed, so tests do not need `zip`.

## License

MIT. The Bravura music font (bundled later) is under the SIL Open Font License.
