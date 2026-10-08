# Web parity fixtures (walk.json)

Copied from the web app (~/dev/music-practice), `frontend/lib/testdata/fixtures/*.walk.json`, source commit: uncommitted, after `4ea725d` (adds `tie-cross-voice`).
They record what OSMD 2.1.3 produces for `walkCursor` (frontend/lib/score_walk.ts); see the web repo's
`frontend/lib/testdata/fixtures/README.md` for every OSMD behaviour they pin. The inputs are the starters
(`../<name>.musicxml`) and the edge cases (`../edge/<name>.musicxml`; `ode-to-joy-mxl` is `../edge/ode-to-joy.mxl`).
The `*.score.json` files (MusicCore's concern) are not copied. Regenerate with `deno task score-fixtures` in the web repo.
