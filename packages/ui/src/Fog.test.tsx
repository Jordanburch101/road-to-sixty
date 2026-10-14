import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Fog } from "./Fog";

test("each fog keeps its own speed, and each road its own colour", () => {
  const roads: [number, number][][] = [[[0, 20], [200, 20]], [[0, 180], [200, 180]]];
  const html = renderToStaticMarkup(<Fog width={200} height={200} step={20} roads={roads} animate={9} colours={["#3aa0ff", "#f7f4ee"]} />);
  expect(html).toContain("animation-duration:9s");
  expect(html).toContain("fill:#f7f4ee");
});

test("a still fog has no animation", () => {
  const html = renderToStaticMarkup(<Fog width={100} height={100} step={20} roads={[[[0, 50], [100, 50]]]} />);
  expect(html).not.toContain("animation");
});
