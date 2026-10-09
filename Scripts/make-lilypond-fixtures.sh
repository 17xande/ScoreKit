#!/bin/sh
# Rebuild Tests/ScoreKitTests/Fixtures/complex/lilypond/*.mxl from a checkout of the LilyPond
# unofficial MusicXML test suite (MIT, see that folder's LICENSE):
#   git clone --depth 1 --filter=blob:none --sparse https://github.com/lilypond/lilypond.git
#   (cd lilypond && git sparse-checkout set input/regression/musicxml)
#   Scripts/make-lilypond-fixtures.sh lilypond/input/regression/musicxml
# Needs `zip`; the outputs are committed so tests don't.
set -eu
src=$(cd "$1" && pwd)
out="$(cd "$(dirname "$0")/.." && pwd)/Tests/ScoreKitTests/Fixtures/complex/lilypond"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for s in 03e-Rhythm-No-Divisions 13a-KeySignatures 13e-KeySignatures-Cancel 21d-Chords-SchubertStabatMater \
         23a-Tuplets 23d-Tuplets-Nested 24a-GraceNotes 33b-Spanners-Tie 41h-TooManyParts \
         43a-PianoStaff 45a-SimpleRepeat 45b-RepeatWithAlternatives 45c-SimpleRepeat-Nested \
         45d-Repeats-MultipleEndings 45i-Repeats-Nested 46d-PickupMeasure-ImplicitMeasures \
         51a-Header-Credits 51b-Header-Quotes 51c-MultipleMetadata 51d-EmptyTitle; do
  rm -rf "$tmp/w"; mkdir -p "$tmp/w/META-INF"; cp "$src/$s.xml" "$tmp/w/$s.xml"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<container><rootfiles><rootfile full-path="%s.xml" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles></container>\n' "$s" > "$tmp/w/META-INF/container.xml"
  rm -f "$out/$s.mxl"
  (cd "$tmp/w" && zip -q -X -9 "$out/$s.mxl" META-INF/container.xml "$s.xml")
done
