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

## Hosting the videos (needs the owner's go-ahead)

The page opens each video with a short-lived link from a **private** Storage bucket named `tutorials`, holding `<id>.mp4`. Nothing has been created in the live project. Until the bucket and files exist, opening a video shows the written steps and says the video is not available to watch yet.

To switch it on, with the same pattern the artwork bucket uses (a numbered migration, next is 92; the bucket is private and only people with a Flow role can read it, decorators cannot):

```sql
insert into storage.buckets (id, name, public) values ('tutorials', 'tutorials', false) on conflict (id) do nothing;
create policy tutorials_staff_read on storage.objects for select to authenticated using (bucket_id = 'tutorials' and flow.is_member());
create policy tutorials_admin_upload on storage.objects for insert to authenticated with check (bucket_id = 'tutorials' and flow.has_role('admin'));
```

Then upload `video/out/<id>.mp4` as `<id>.mp4`. The MP4s are not committed to the repo.

## Known limits

- The screenshots come from the mocked backend, which does not change state after an action (for example a purchase order stays "Draft" after approving). The videos therefore show a celebratory pop-up for the success moment, which is an overlay and not the app.
- Speech recognition checks catch mispronounced words, but nobody has listened to the finished videos yet: have a person watch each one before it is shared.
