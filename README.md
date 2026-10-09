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

## Piano part and the SVG tool

A score with a piano part can be laid out with only that part: `var o = LayoutOptions(width: ...);
o.restrict(toPianoOf: score)` sets `staves` to the piano part(s) (`LayoutOptions.pianoStaves(of:)`,
`Score.pianoPartIndices`); a score without one is laid out whole. Tempo marks of the hidden parts
are still drawn. `hideEmptyStaves` drops staves that hold only rests.

`swift run scorekit-svg score.mxl > out.svg` is a debug tool that renders a layout as SVG. Like the
app, it shows only the piano part(s) by default: pass `--all-parts` for every part, `--hide-empty`
to drop empty staves, `--measure N` to crop to the system holding measure N (1-based position).

## Non-goals

Slurs, dynamics, articulations, lyrics, cross-staff beams, 8va lines, pedal,
timewise scores, editing, MIDI/audio output, and pixel parity with any other
renderer. Tuplets (brackets and numbers) and grace notes are drawn; D.C./D.S./Coda/Fine
jumps are followed by the timeline.

## Status

Under construction: file reading (.mxl via ZIPFoundation, XML tree) is in place; model,
timeline and layout follow.

## Test fixtures

`Scripts/make-mxl.sh` regenerates the `.mxl` fixtures in
`Tests/ScoreKitTests/Fixtures` from the `.musicxml` files there. The generated
files are committed, so tests do not need `zip`.

The complex-score fixtures in `Tests/ScoreKitTests/Fixtures/complex` keep their own
licences, with sources beside them: `openscore/` is five OpenScore Lieder transcriptions
(CC0 1.0) and `lilypond/` is a selection of the LilyPond unofficial MusicXML test suite
(MIT, Reinhold Kainhofer). `Scripts/make-lilypond-fixtures.sh` rebuilds the latter.

Where the web app's OSMD/VexFlow output differs from correct engraving or playback, see
[docs/osmd-vexflow-limitations.md](docs/osmd-vexflow-limitations.md).

## License

MIT. The Bravura music font (bundled later) is under the SIL Open Font License.
