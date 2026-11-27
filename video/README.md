# ATAM_FLOW how-to videos (Remotion)

Short, upbeat tutorial videos built from screenshots of the real dashboard (synthetic data only), a Kokoro voiceover, and pop-up graphics that fire on the spoken words. Separate from the dashboard: not part of its tests or the GitHub Pages deploy.

Full instructions, hosting and limits: [../docs/how-to-videos.md](../docs/how-to-videos.md).

```bash
npm install
npm run capture      # screenshots of the real dashboard (build it first: cd ../apps/dashboard && npm run build)
npm run voice        # voiceover, timing, music and sound effects
npm run render       # out/<id>.mp4
npm run studio       # live preview
```
