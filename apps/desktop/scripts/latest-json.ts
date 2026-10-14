// The updater's latest.json for one release, in Tauri's format: every
// platform needs a url and the text of its .sig file. The updater has no
// universal Mac entry, so both Mac processors point at the universal build.
//
//   bun scripts/latest-json.ts <version> <base url> <folder with the builds>

export type Built = { file: string; signature: string };

export function latestJson(o: { version: string; base: string; pubDate: string; mac: Built; windows: Built }) {
  const at = (b: Built) => ({ url: `${o.base}/app/${o.version}/${b.file}`, signature: b.signature });
  return {
    version: o.version,
    notes: `Road to Sixty ${o.version}`,
    pub_date: o.pubDate,
    platforms: { "darwin-aarch64": at(o.mac), "darwin-x86_64": at(o.mac), "windows-x86_64": at(o.windows) },
  };
}

if (import.meta.main) {
  const [version, base, folder] = Bun.argv.slice(2);
  if (!version || !base || !folder) throw new Error("usage: latest-json.ts <version> <base url> <folder>");
  const built = async (file: string) => ({ file, signature: (await Bun.file(`${folder}/${file}.sig`).text()).trim() });
  const json = latestJson({
    version,
    base,
    pubDate: new Date().toISOString(),
    mac: await built("Road-to-Sixty.app.tar.gz"),
    windows: await built(`Road-to-Sixty_${version}_x64-setup.exe`),
  });
  console.log(JSON.stringify(json, null, 2));
}
