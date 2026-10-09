# OSMD / VexFlow limitations (what the web app inherits)

**How to use this doc.** The web app renders with OpenSheetMusicDisplay (OSMD) 2.1.3 on VexFlow 5.0.0 and plays
from OSMD's repeat walk. ScoreKit targets correct engraving (Behind Bars, Elaine Gould; SMuFL) and correct
playback, not OSMD's behaviour. When web output differs from ScoreKit, look up the topic below. A row marked
**library limitation** means the web is wrong and ScoreKit should not copy it. **app intent** means the web
differs on purpose. **unknown** means nobody has checked. Issue numbers come from GitHub search and `gh issue view`
(2026-10-09); "unverified" marks anything from memory or not reproduced. Repo links:
`https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/N` (written `osmd#N`) and
`https://github.com/vexflow/vexflow/issues/N` (`vf#N`).

Repro details, causes and proposed upstream fixes live in the web repo's `docs/upstream-bugs.md`
(`~/dev/music-practice/docs/upstream-bugs.md`); this doc is the short "what the web shows vs correct" reference.

**Version warning.** OSMD **2.2.0 shipped 2026-10-02**, after the web's 2.1.3 (2026-09-19). Its
[changelog](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/blob/develop/CHANGELOG.md) has ~20
"Repetition" fixes (details below), so some walk differences are "fixed upstream, web not upgraded". Several
2.1.3 behaviours in `frontend/lib/testdata/fixtures/README.md` ("OSMD probes") are not mentioned in the 2.2.0
changelog. The fixtures were re-run on 2.2.0 (2026-10-09; results per behaviour in `upstream-bugs.md`): they are
still present in 2.2.0 except tempo `<offset>`, which 2.2.0 fixes. The tie-order bug was not re-run.
VexFlow: 5.0.0 is the latest release (2025-03-05); the VexFlow issue tracker is small and mostly about API/formatter
gaps, so VexFlow bugs rarely have an issue number. VexFlow claims without a link are from memory (unverified).

## 1. Repeats, voltas, D.C./D.S./Coda/Fine (playback walk)

| Behaviour in 2.1.3 | Correct | Verdict |
|---|---|---|
| `<repeat times="3">` plays twice (`Times` never read; fixture `repeat-times-3`). Not in 2.2.0 changelog. | Play `times` passes (MusicXML spec). | library limitation |
| Ending `number="1, 2"` keeps first digit only (`ending-multi-number`); not in 2.2.0 changelog. | Parse lists/ranges: endings "1, 2" then "3" play 1 2 1 2 1 3 4. | library limitation |
| Ending text overrides `number`; text without digits drops measures; swapped digits play the piece twice (`ending-text-differs`, `ending-text-digits-swapped`). Related, closed: [osmd#1367](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1367) (number read from `<ending>` text). | `number` governs, text is only the label. | library limitation |
| `print-object="no"` ending: the walk plays 1 2 1 2 3 4 instead of 1 2 1 3 4 (`ending-print-object-no`; same in 2.2.0). Changelog (older entry, ~v1.8) says "Respect print-object=no" for voltas. | Hidden bracket must still play. | library limitation |
| Tempo `<offset>` mid-measure never applies in 2.1.3 (fixed in 2.2.0); `tempo="fast"` resets to 100; `tempo="0"` gives 60 (0 in 2.2.0); half=60 plays as 60 quarters/min (probes 1, 2, 4). 2.2.0 only adds "keep current tempo at metronome marks without BPM" ([osmd#1756](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/pull/1756)) and metric modulation. | Follow MusicXML: offset only with `sound="yes"`; ignore invalid tempo; convert beat unit/dots. | library limitation (beat-unit conversion is optional per `docs/ipad-divergences.md`) |
| Ties resolved in score order, not played order (tie before `:|` claims note after volta; tie into ending 2 lost). | Resolve over the unrolled sequence. | library limitation |
| D.C./D.S./Fine/To Coda before 2.2.0: read from words only, `<sound>` jumps ignored or wrong, repeats retaken after a jump, whole piece played twice for D.C. al Coda, endless loops. 2.2.0 fixes many ([osmd#1759](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/pull/1759), [osmd#1758](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/pull/1758), plus unnumbered commits in the 2.2.0 changelog). Note probe 12 says `dc-al-fine` works in 2.1.3 for the simple case. | Repeats are not retaken after D.C./D.S. (convention, Behind Bars "Repeats" / jumps) unless "with repeats"; Fine/To Coda only honoured on the jump pass. | library limitation, fixed upstream in 2.2.0 (unverified on web fixtures) |
| A jump `<sound>` at the very start of a measure acts one measure late ([osmd#1766](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1766), closed; Dorico writes jumps this way; fixed by a2cb478, [PR #1807](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/pull/1807) on `develop` after 2.2.0, so **not** in 2.2.0). | `<sound>` acts at the current position, i.e. the barline before the measure. | library limitation, fixed on `develop`, not in a release |
| "D.C. senza replica" drawn as "D.C." ([osmd#1767](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1767), closed). | Draw the words as written. | library limitation (regression from #1759, fixed in 2.2.0) |
| Cursor ignored repeats entirely early on ([osmd#379](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/379), closed 2026-02); `cursor.next()` follows repeats since a 1.9.x/2.0 fix (PR #1644 in changelog). | Playback follows the unrolled sequence. | fixed upstream |
| Rendering: repeat start at line start drawn wrongly ([osmd#901](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/901), closed); multi-measure volta shows gap ([osmd#1686](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1686), closed); voltas interrupted ([osmd#1615](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1615), closed); D.S./coda x-positions ([osmd#920](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/920), closed). | Volta bracket continuous over all its measures, hooks only at the ends (Behind Bars, "Repeats and first/second-time bars"; chapter number not verified). | fixed upstream; re-check in the web render |
| Measure-repeat (simile) signs not drawn until 2.2.0 ([osmd#877](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/877)). | SMuFL `repeat1Bar` / `repeat2Bars` glyphs (Repeats range). | library limitation in 2.1.3 |

Not seen/unverified: OSMD handling of `segno`/`coda` attributes on non-adjacent measures with multiple movements; repeat `winged`/`direction` details.

## 2. 8va / ottava lines

- VexFlow has no ottava object; it uses `TextBracket` (text + dashed line + end hook). OSMD draws octave-shift
  brackets itself on top of it. (From memory, unverified.)
- History of bugs, all closed: line ended at last note instead of measure end, multi-system lines wrong
  ([osmd#1378](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1378)); single-note 8va with
  `<backup>` wrong start/end and shifted sounding pitch ([osmd#1645](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1645),
  fixed 2.0.x, PR #1647); crash on unterminated shift (PR #1696); line not reaching the end in in-between systems
  (PR #1646); octave shifts calculated after chord symbols/dynamics so they collide
  ([osmd#1775](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1775), closed in 2.2.0).
- Correct: sounding pitch = written +/- octaves for the span; line runs to the last note's end (Behind Bars, "Octave lines";
  8va/15ma/8vb/15mb labels, SMuFL `ottava`, `ottavaBassa`, `quindicesima`). Verdict: library limitation where the
  span or playback octave differs; playback octave from the span is an app-side responsibility (unknown how the web applies it).

## 3. Pedal

- Supported since [osmd#347](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/347) (closed). Fixed bugs:
  pedal across full measure instead of stopping before last note ([osmd#1291](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1291)),
  missing at system break ([osmd#1292](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1292)),
  too low ([osmd#1330](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1330)),
  starting on a rest mis-positioned ([osmd#1306](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1306)).
  No open pedal issue seen. VexFlow's `PedalMarking` supports Ped./star text and bracket styles; mixed style
  (Ped. then line with change marks) fidelity: unverified.
- OSMD does not use pedal for audio (it has no playback; `cursor` only). Any sustain playback is app work.
- Correct: Ped. at press, star or bracket end at release; bracket with change notches (Behind Bars, "Pedalling"; SMuFL `keyboardPedalPed`, `keyboardPedalUp`).
  Verdict: mostly fixed upstream; unknown for half-pedal/change forms.

## 4. Slurs

- Open: [osmd#228](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/228) (slur code refactor, long-standing).
  Closed: "bloated" slurs ([osmd#1466](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1466), fixed 2.0.x by flattening over long
  distances/obstacles, PR #1693; an approximation, not Gould's rules); cross-staff slurs
  ([osmd#1006](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1006), 1.9.x); slurs colliding with accents/staccato
  ([osmd#1224](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1224)); crossed slurs ([osmd#400](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/400));
  NaN path for start plus orphan stop; start/stop on same note (Dolet) only drawn in 2.2.0. Open: tie with no start/end note not rendered
  ([osmd#712](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/712), [osmd#713](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/713)).
- VexFlow `Curve`/`StaveTie` give a simple Bezier; slur placement rules (outside stems, over/under by stem direction, start/end
  clearance from noteheads) are approximated. Vexflow style issue [vf#221](https://github.com/vexflow/vexflow/issues/221) is cosmetic only.
- Correct: slur on the notehead side unless it spans stem-down and stem-up mixed (then above); avoids stems and articulations (Behind Bars, "Slurs").
  Verdict: library limitation (approximate); acceptable differences are shape, not endpoints.

## 5. Multiple voices per staff

- VexFlow does not resolve collisions across voices in the formatter: rests colliding with other voices'
  notes ([vf#203](https://github.com/vexflow/vexflow/issues/203), open) and general vertical collisions
  ([vf#206](https://github.com/vexflow/vexflow/issues/206), open, asks if the caller should detect them).
  OSMD adds its own stagger/rest-offset logic; results seen as bugs, mostly closed: rest drawn between staves when a
  note of another voice crosses staff ([osmd#1800](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1800)), hidden unison heads
  ([osmd#1729](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1729), [osmd#1038](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1038)),
  unison between two voices in a 3-voice staff (PR #1677), whole/half rest positions reversed
  ([osmd#893](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/893), open), misaligned voices with dotted durations (PR #1697),
  secondary voice alone in measure forced stems-down (option `AutoStemSecondaryVoicesWhenAloneInMeasure`, 2.1.x).
- Correct: voice 1 stems up / voice 2 down; rests of the second voice shift away; unisons share a head when
  same value (Behind Bars, "Multiple voices"/"Two voices on one staff"). Verdict: library limitation (heuristics, ongoing fixes).
- Playback: OSMD iterator walks all voices at the same timestamps; `<backup>`/`<forward>` handled, `<forward>` positions are skipped as invisible (README "Invisible positions").

## 6. Dynamics and hairpins

- Fixed: combined dynamics (`sfmp`, `ffz`) rendered only first child
  ([osmd#1705](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1705), 2.1.3); dynamic + wedge in one `<direction>`
  ([osmd#1018](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1018)); wedge length ([osmd#1477](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1477)),
  multi-instrument start x ([osmd#1480](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1480)), multi-line hairpins
  ([osmd#1277](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1277)), wedge offset ignored ([osmd#1525](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1525));
  dim. overlapping next staff ([osmd#758](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/758)); 2.2.0: dynamics drawn over the clef, wedges across the staff (PR #1734).
  Open: relative-x/y attributes unsupported ([osmd#1623](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1623)); dashes/bracket (e.g. "cresc. ---") not rendered
  ([osmd#1563](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1563), [osmd#940](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/940)).
- Correct: dynamics below staff (above for vocal) aligned to note, hairpins level and end before next dynamic (Behind Bars, "Dynamics"/"Hairpins").
  Dynamic playback levels in OSMD are derived from text (2.1.3: ffz -> ff); velocity mapping is the app's. Verdict: mixed; `relative-x/y` and dashes are library limitations.

## 7. Articulations

- Fixed/closed: staccato position ([osmd#921](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/921)), fingering vs articulation
  placement ([osmd#994](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/994)), slur/accent collision (#1224), ornaments with
  `placement="below"` always drawn above until 2.2.0 ([osmd#866](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/866)).
  VexFlow: `Articulation.draw()` not idempotent ([vf#254](https://github.com/vexflow/vexflow/issues/254), open: bounding box changes on re-draw).
  `relative-x/y` ignored (#1623).
- Correct: articulations on the notehead side, stacked with fixed spacing, never inside the staff for staccato beside tied/slurred notes
  (Behind Bars, "Articulation"). Playback: OSMD does not apply staccato/accent to timing/velocity; app work. Verdict: library limitation (placement), app intent (playback).

## 8. Measure numbering

- `measure` from the cursor is index+1, not printed number: a pickup with `implicit="yes"` number 0 reports 1 (README "OSMD behaviours seen"). Web must key on its own mapping.
- Implicit measures get no number by default since 1.9.x ([osmd#1574](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1574), option `RenderMeasureNumbersForImplicitMeasures`);
  first full measure numbered 1 or 2 question: [osmd#1328](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1328);
  first/second ending numbering question [osmd#1326](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1326) (closed, answer not read: unverified);
  `drawFromMeasureNumber` with a pickup rendered one off (fixed); numbers collide with group brackets ([osmd#1430](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/1430), closed) and clip brackets
  ([osmd#362](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/issues/362), open). 2.1.x option `drawMeasureNumbersOnlyAtSystemStart` exists.
- Correct: measure numbers at the start of each system (or every N), pickup unnumbered, numbers printed per the file's `number` attribute, not index
  (Behind Bars, "Bar numbers"). Verdict: app intent for which numbers the web shows; library limitation for collisions.

## Sources / date checked

2026-10-09. GitHub issue/PR search and `gh issue view` for opensheetmusicdisplay/opensheetmusicdisplay and vexflow/vexflow;
OSMD [CHANGELOG.md](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/blob/develop/CHANGELOG.md) (2.2.0, 2.1.3 and 2.0.x/1.9.x entries) and
[release 2.2.0](https://github.com/opensheetmusicdisplay/opensheetmusicdisplay/releases/tag/2.2.0); VexFlow releases (5.0.0, 2025-03-05);
local read-only: `~/dev/music-practice/docs/ipad-divergences.md`, `frontend/lib/testdata/fixtures/README.md`.
Not done: VexFlow 4.x/5.0.0 source-level audit; re-running the tie probe on OSMD 2.2.0; Behind Bars chapter numbers (named by topic only);
fetching each closed issue's resolution (verdicts "fixed" come from the changelog, titles and close dates).
