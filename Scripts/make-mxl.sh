#!/bin/sh
# Rebuild the .mxl test fixtures from the starter .musicxml files.
# Needs `zip`; the outputs are committed so tests don't.
set -eu
cd "$(dirname "$0")/../Tests/ScoreKitTests/Fixtures"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

container() { # $1 = score file name
  mkdir -p META-INF
  cat > META-INF/container.xml <<XML
<?xml version="1.0" encoding="UTF-8"?>
<container><rootfiles><rootfile full-path="$1" media-type="application/vnd.recordare.musicxml+xml"/></rootfiles></container>
XML
}

# Deflate with container.xml (the normal case); mimetype-less like MuseScore.
for s in minuet-in-g ode-to-joy; do
  rm -rf "$tmp/w"; mkdir "$tmp/w"; cp "$s.musicxml" "$tmp/w/"
  (cd "$tmp/w" && container "$s.musicxml" && rm -f "$OLDPWD/$s.mxl" && zip -q -X -9 "$OLDPWD/$s.mxl" META-INF/container.xml "$s.musicxml")
done

# Stored (-0) with container.xml.
s=twinkle-twinkle
rm -rf "$tmp/w"; mkdir "$tmp/w"; cp "$s.musicxml" "$tmp/w/"
(cd "$tmp/w" && container "$s.musicxml" && rm -f "$OLDPWD/$s-stored.mxl" && zip -q -X -0 "$OLDPWD/$s-stored.mxl" META-INF/container.xml "$s.musicxml")

# Deflate without container.xml (fallback to first .musicxml).
s=bach-prelude-in-c
rm -rf "$tmp/w"; mkdir "$tmp/w"; cp "$s.musicxml" "$tmp/w/"
(cd "$tmp/w" && rm -f "$OLDPWD/$s-nocontainer.mxl" && zip -q -X -9 "$OLDPWD/$s-nocontainer.mxl" "$s.musicxml")

# Container points into a subfolder; a decoy a.xml comes first in the archive.
rm -rf "$tmp/w"; mkdir -p "$tmp/w/scores/main"; cp ode-to-joy.musicxml "$tmp/w/scores/main/ode.musicxml"
(cd "$tmp/w" && echo '<decoy/>' > a.xml && container "scores/main/ode.musicxml" \
  && rm -f "$OLDPWD/subfolder.mxl" && zip -q -X -9 "$OLDPWD/subfolder.mxl" a.xml META-INF/container.xml scores/main/ode.musicxml)

# Container lists a typed PDF, an untyped junk .xml, then the real score.
rm -rf "$tmp/w"; mkdir "$tmp/w"; cp minuet-in-g.musicxml "$tmp/w/score.musicxml"
(cd "$tmp/w" && printf '%%PDF-1.4 not really a pdf\n' > score.pdf && echo 'not xml at all' > junk.xml \
  && mkdir -p META-INF && cat > META-INF/container.xml <<XML
<?xml version="1.0" encoding="UTF-8"?>
<container><rootfiles>
<rootfile full-path="score.pdf" media-type="application/pdf"/>
<rootfile full-path="junk.xml"/>
<rootfile full-path="score.musicxml" media-type="application/vnd.recordare.musicxml+xml"/>
</rootfiles></container>
XML
  rm -f "$OLDPWD/pdf-rootfile.mxl" && zip -q -X -9 "$OLDPWD/pdf-rootfile.mxl" META-INF/container.xml score.pdf junk.xml score.musicxml)

# Only junk .xml files: no score at all.
rm -rf "$tmp/w"; mkdir "$tmp/w"
(cd "$tmp/w" && echo '<foo/>' > a.xml && echo 'not xml' > b.xml \
  && rm -f "$OLDPWD/junk-only.mxl" && zip -q -X -9 "$OLDPWD/junk-only.mxl" a.xml b.xml)
