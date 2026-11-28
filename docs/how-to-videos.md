# How-to videos

Short, friendly tutorial videos for the team, with a **How-to videos** page in the dashboard (Control menu, `#/howto`, keyboard `g` then `4`). Pick a video to watch it; the same steps are written out underneath, with a button that opens the real page.

## What is in the repo

| Path | What it is |
|---|---|
| `video/` | The video project (Remotion + Kokoro voice). Separate from the dashboard: not part of its tests or the Pages deploy. |
| `video/src/tutorials.json` | Every tutorial: title, who it is for, and for each step the screenshot, the zoom target, the spoken line and the pop-ups (each tied to a word in the line). |
| `video/capture/capture.mjs` | Takes clean screenshots of the **real dashboard** running against the same fully mocked backend the browser tests use (synthetic data only, never the live database or n8n). It also records where each interesting element is, so zooms and highlights follow the real layout. |
| `apps/dashboard/src/pages/HowTo.tsx`, `lib/howto.ts` | The page, and its list/search logic (unit tested). |
| `apps/dashboard/src/data/howto.generated.json` | The list the page shows, generated from `tutorials.json` (`npm run catalogue`). |
| `apps/dashboard/public/howto/*.jpg` | Poster images for the cards (`npm run posters`). |

## The library so far

| Video | Topic | Who it is for |
|---|---|---|
| Meet your Command Centre | Getting started | Everyone |
| Find any order, fast | Orders | Everyone |
| Why the system says this | Orders | Everyone |
| The holding pen | Orders | Everyone |
| Raise and approve a purchase order | Stock and buying | Managers and admins |
| Stock and shortage advice | Stock and buying | Everyone |
| Review supplier emails | Stock and buying | Managers and admins |
| Generate and print labels | Warehouse | Warehouse and managers |
| Book a delivery in | Warehouse | Warehouse and managers |
| Dispatch and courier labels | Warehouse | Warehouse and managers |
| Artwork, proofs and job packs | Artwork and quality | Managers and production |
| Quality checks and rework | Artwork and quality | Warehouse and managers |
| Exceptions: raise, assign, resolve | Admin | Everyone |

Not yet made are the in-house production screens (Production, Machine downtime, Crew and floor, Embroidery, DTF): in-house production is switched off for the third-party launch, so a video would show something staff cannot use yet. They are listed on the page as waiting for in-house to be switched on.

## Make or change a video

```bash
cd apps/dashboard && npm ci && npm run build        # the capture runs the built dashboard
cd ../../video && npm install
pip install kokoro-onnx soundfile numpy scipy sherpa-onnx
# KOKORO_DIR: kokoro-v1.0.int8.onnx + voices-v1.0.bin (github.com/thewh1teagle/kokoro-onnx, release model-files-v1.0)
# WHISPER_DIR: sherpa-onnx-whisper-base.en (github.com/k2-fsa/sherpa-onnx, release asr-models) for the checks
npm run capture                                     # screenshots -> public/shots, positions -> src/shots.json
npm run voice                                       # voice lines, timing.json, music + sound effects
python3 audio/check_voice.py <id>                   # speech recognition on each line: catches mispronunciations
python3 audio/check_mix.py <id>                     # loudness, peaks, voice over music, recognition on the finished mix
npm run render                                      # out/<id>.mp4 (set BROWSER if Remotion cannot download Chrome)
npm run catalogue && npm run posters                # refresh the dashboard's list and posters
```

To add a tutorial: add a scene to `capture/capture.mjs` (drive the app, call `snap` with named elements), add an entry to `tutorials.json`, then run the steps above. A pop-up fires when its `on` word is spoken, so the graphics always match the voice. Kinds: `sticker`, `arrow`, `ring`, `keys`, `stamp`, `confetti`.

Rules for the content: use made-up sample data only, show only what is built and live (see `docs/ui.md` and `docs/launch-checklist.md`), do not invent figures, and say plainly when a number is a placeholder setting ("as set up here").

## The voice

The three pilot videos are narrated by **Brady J, "Friendly, Casual, Warm"** from ElevenLabs (model `eleven_v4`). Kokoro (free, built into the project) is the fallback and is what `npm run voice` makes.

To voice a tutorial with Brady J:

1. `python3 audio/el_lines.py <id>` prints each line as plain text, with spelled-out letters separated ("A T A M", "P O", "Q R") so they are read as letters.
2. Generate each line with the ElevenLabs voice **one take per line** (a retry is charged again), and save the files as `<key>.mp3` (`a.mp3`, `b.mp3`, ...) in a folder.
3. `python3 audio/import_voice.py <id> <folder>` trims and imports them and records each length. Then run `make_timing.py`, `make_audio_tutorial.py`, `check_voice.py` and `check_mix.py` as usual. The pop-ups follow the spoken words, so they re-time themselves.

Cost: about one credit (character) per character of text, roughly 700 characters per video. The Creator plan is 138,805 characters a month, so the whole planned library of about 40 videos fits in one month if nothing else uses the plan. Re-voicing a video after a script change costs that video's characters again.

## Hosting the videos (bucket applied and the three pilot videos uploaded, 27 Nov 2026)

The page opens each video with a short-lived link from a **private** Storage bucket named `tutorials`, holding `<id>.mp4`. Until the bucket and files exist, opening a video shows the written steps and says the video is not available to watch yet.

Migration 92 (`supabase/migrations/20261127000092_flow_tutorials_bucket.sql`, test `supabase/tests/tutorials_bucket_test.sql`) makes the bucket and its rules. It is **applied to the live project** (27 Nov 2026, with the owner's go-ahead; checked after: private, mp4 only, 200 MB, three rules). The three pilot videos were then uploaded and checked (sizes and a downloaded copy matched the local files).

| Who | Can |
|---|---|
| Admin, manager, production, warehouse, viewer | Watch (read) |
| Admin | Add a video, or replace one |
| Everyone else (a login with no Flow role, a decorator, a signed-out visitor) | Nothing |

The bucket is private, mp4 only, and 200 MB per file. There is no delete rule: remove a file from the Supabase dashboard if one is ever needed. Where there is no storage schema (the local test database) the migration does nothing, so the test runs the real file against a stand-in.

For each new video: upload `video/out/<id>.mp4` as `<id>.mp4` (Supabase dashboard, Storage, `tutorials`), then sign in as a viewer and open a video on the How-to page, and check a decorator login cannot. The MP4s are not committed to the repo.

## Known limits

- The screenshots come from the mocked backend, which does not change state after an action (for example a purchase order stays "Draft" after approving). The videos therefore show a celebratory pop-up for the success moment, which is an overlay and not the app.
- Speech recognition checks catch mispronounced words, but nobody has listened to the finished videos yet: have a person watch each one before it is shared.
