import { Composition } from "remotion";
import "@fontsource/fredoka/400.css"; import "@fontsource/fredoka/500.css"; import "@fontsource/fredoka/600.css"; import "@fontsource/fredoka/700.css";
import tutorials from "./tutorials.json";
import timing from "./timing.json";
import { Tutorial } from "./Tutorial";
import { FPS, H, W } from "./theme";

export const Root = () => (
  <>
    {tutorials.map((t) => {
      const tm = (timing as Record<string, { total: number }>)[t.id];
      return <Composition key={t.id} id={t.id} component={Tutorial} width={W} height={H} fps={FPS} durationInFrames={Math.ceil(tm.total * FPS)} defaultProps={{ id: t.id }} />;
    })}
  </>
);
