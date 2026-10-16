import { Button } from "@road-to-sixty/ui/Button";
import { useEffect, useState, type ReactNode } from "react";
import {
  checkUpdate, deleteAccount, devices, exportData, installAddon, installUpdate, isMac, pickFolder, renameDevice,
  setAddonUpdates, setStartsAtLogin, startsAtLogin, unlink, unlinkDevice, updateAddon, useLoad, type Status,
} from "./api";
import { Shell, type Tab } from "./Characters";
import { deviceLine, folderWords, gameName, installFolder, updateWords } from "./format";

const small = "h-[30px] whitespace-nowrap rounded-lg px-3 text-xs";

export function Account({ status, onTab }: { status: Status; onTab: (t: Tab) => void }) {
  const pcs = useLoad(devices, [status.lastSynced]);
  const [renaming, setRenaming] = useState<{ id: string; name: string } | null>(null);
  // Which inline question is open: a PC's id, "this PC" or "delete".
  const [asking, setAsking] = useState<string | null>(null);
  const [error, setError] = useState<{ at: string; why: string } | null>(null);
  const [atLogin, setAtLogin] = useState(false);
  const [checked, setChecked] = useState<string | null | undefined>(undefined);
  const [saved, setSaved] = useState(false);
  const now = new Date();
  useEffect(() => void startsAtLogin().then(setAtLogin, () => {}), []);

  const act = (at: string, job: () => Promise<unknown>) => async () => {
    setError(null);
    try {
      await job();
    } catch (e) {
      setError({ at, why: String(e) });
    }
  };
  const problem = (at: string) => error?.at === at && <p className="mx-1 text-xs text-warn">{error.why}</p>;

  return (
    <Shell status={status} tab="account" onTab={onTab}>
      <div className="flex flex-1 flex-col gap-[22px] overflow-y-auto [scrollbar-gutter:stable] px-4 pb-5 pt-4 text-[13px]">
        <Section title="Your PCs">
          <Card>
            {pcs.data?.map((d, n) => (
              <Row key={d.id} line={n > 0}>
                {renaming?.id === d.id ? (
                  <form
                    className="flex flex-1 flex-col gap-2"
                    onSubmit={(e) => {
                      e.preventDefault();
                      void act("pcs", async () => {
                        await renameDevice(d.id, renaming.name);
                        setRenaming(null);
                        pcs.reload();
                      })();
                    }}
                  >
                    <label htmlFor={`name-${d.id}`} className="sr-only">
                      PC name
                    </label>
                    <div className="flex gap-2">
                      <input
                        id={`name-${d.id}`}
                        value={renaming.name}
                        maxLength={40}
                        autoFocus
                        autoComplete="off"
                        onChange={(e) => setRenaming({ id: d.id, name: e.target.value })}
                        className="h-8 min-w-0 flex-1 rounded-lg border border-accent bg-ground px-2.5 text-sm text-text outline-none"
                      />
                      <Button look="cream" type="submit" className="h-8 rounded-lg px-3 text-xs">
                        Save
                      </Button>
                    </div>
                    <div className="text-xs text-muted">{deviceLine(d, now)}</div>
                  </form>
                ) : asking === d.id ? (
                  <Ask
                    question={`Unlink ${d.name}? It stops syncing at once. Its journeys stay on it and on the server.`}
                    yes="Unlink"
                    onYes={act("pcs", async () => {
                      await unlinkDevice(d.id);
                      setAsking(null);
                      pcs.reload();
                    })}
                    onNo={() => setAsking(null)}
                  />
                ) : (
                  <>
                    <div className="flex min-w-0 flex-1 flex-col gap-1">
                      <div className="flex items-baseline gap-2">
                        <span className="truncate text-sm font-medium">{d.name}</span>
                        {d.id === status.pc && <span className="text-xs text-accent">This PC</span>}
                      </div>
                      <div className="text-xs text-muted">{deviceLine(d, now)}</div>
                    </div>
                    <button type="button" onClick={() => setRenaming({ id: d.id, name: d.name })} className="px-1 py-1.5 text-xs text-[#c9c4d6] hover:text-text">
                      Rename
                    </button>
                    {d.id !== status.pc && (
                      <Button className={small} onClick={() => setAsking(d.id)}>
                        Unlink
                      </Button>
                    )}
                  </>
                )}
              </Row>
            ))}
            {!pcs.data && <Row>{pcs.error ? <span className="text-xs text-warn">Couldn't load your PCs: {pcs.error}</span> : <span className="text-xs text-faint">Loading…</span>}</Row>}
          </Card>
          {problem("pcs")}
          <p className="mx-1 text-xs leading-[1.45] text-faint">Unlinking a PC stops it syncing at once. Its journeys stay on it and on the server.</p>
        </Section>

        <Section title="Game folders">
          {status.folders.map((f) => {
            const w = folderWords(f, Math.floor(Date.now() / 1000));
            return (
              <Card key={f.path}>
                <Row>
                  <div className="flex min-w-0 flex-1 flex-col gap-1">
                    <div className="flex items-baseline gap-2">
                      <span className="text-sm font-medium">{gameName(f.name)}</span>
                      {w.action === "install" ? (
                        <Button className={`ml-auto ${small}`} onClick={act("folders", () => installAddon(f.path))}>
                          Install the addon
                        </Button>
                      ) : (
                        <span className="ml-auto shrink-0 text-xs text-muted">{f.characters === 1 ? "1 character" : `${f.characters} characters`}</span>
                      )}
                    </div>
                    <div className="flex items-center gap-2">
                      <span className={`text-xs ${w.warn ? "text-warn" : "text-muted"}`}>{w.line}</span>
                      {w.action === "update" && (
                        <Button className={`ml-auto ${small}`} onClick={act("folders", () => updateAddon(f.path))}>
                          Update
                        </Button>
                      )}
                    </div>
                    <div className="text-[11.5px] text-faint [overflow-wrap:anywhere]" title={f.path}>
                      {installFolder(f.path, f.name)}
                    </div>
                  </div>
                </Row>
              </Card>
            );
          })}
          {problem("folders")}
          <Button className="h-[30px] self-start rounded-lg px-3 text-xs" onClick={pickFolder}>
            Add a game folder…
          </Button>
        </Section>

        <Section title="This PC">
          <Card>
            <Row>
              <label htmlFor="atlogin" className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Start at login</span>
                <span className="text-xs leading-[1.45] text-muted">Opens hidden in the {isMac ? "menu bar" : "tray"}, so every session is backed up.</span>
              </label>
              <button
                id="atlogin"
                type="button"
                role="switch"
                aria-checked={atLogin}
                onClick={act("login", async () => {
                  await setStartsAtLogin(!atLogin);
                  setAtLogin(await startsAtLogin());
                })}
                className={`flex h-6 w-10 shrink-0 rounded-full p-[3px] ${atLogin ? "justify-end bg-accent" : "justify-start bg-outline"}`}
              >
                <span className="size-[18px] rounded-full bg-cream" />
              </button>
            </Row>
            {error?.at === "login" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't change it: {error.why}</p>}
            <Row line>
              <label htmlFor="addonupdates" className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Keep the addon up to date</span>
                <span className="text-xs leading-[1.45] text-muted">New versions install while WoW is closed. A developer copy is never changed.</span>
              </label>
              <button
                id="addonupdates"
                type="button"
                role="switch"
                aria-checked={status.addonUpdates}
                onClick={act("addon", () => setAddonUpdates(!status.addonUpdates))}
                className={`flex h-6 w-10 shrink-0 rounded-full p-[3px] ${status.addonUpdates ? "justify-end bg-accent" : "justify-start bg-outline"}`}
              >
                <span className="size-[18px] rounded-full bg-cream" />
              </button>
            </Row>
            {error?.at === "addon" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't change it: {error.why}</p>}
            <Row line>
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Road to Sixty {status.version}</span>
                <span className="text-xs leading-[1.45] text-muted">{updateWords(status.update, checked)}</span>
              </div>
              {status.update.state === "ready" ? (
                <Button className={small} onClick={act("update", installUpdate)}>
                  Restart now
                </Button>
              ) : (
                <Button className={small} onClick={act("update", async () => setChecked(await checkUpdate()))}>
                  Check now
                </Button>
              )}
            </Row>
            {error?.at === "update" && <p className="px-3.5 pb-3 text-xs text-warn">Couldn't check: {error.why}</p>}
            <Row line>
              {asking === "this PC" ? (
                <Ask
                  question="Unlink this PC? Syncing stops here. Your journeys stay on this PC and on the server."
                  yes="Unlink"
                  onYes={act("unlink", unlink)}
                  onNo={() => setAsking(null)}
                />
              ) : (
                <>
                  <div className="flex flex-1 flex-col gap-1">
                    <span className="text-sm font-medium">Linked to {status.linkedTo}</span>
                    <span className="text-xs leading-[1.45] text-muted">Unlink to stop syncing here.</span>
                  </div>
                  <Button className={small} onClick={() => setAsking("this PC")}>
                    Unlink
                  </Button>
                </>
              )}
            </Row>
          </Card>
          {problem("unlink")}
        </Section>

        <Section title="Your data">
          <Card>
            <Row>
              <div className="flex flex-1 flex-col gap-1">
                <span className="text-sm font-medium">Download all my data</span>
                <span className="text-xs leading-[1.45] text-muted">{saved ? "Saved." : "A zip with each character's newest journey."}</span>
              </div>
              <Button className={small} onClick={act("data", async () => setSaved(await exportData()))}>
                Download
              </Button>
            </Row>
            <Row line>
              {asking === "delete" ? (
                <Ask
                  question="Delete your account and every journey on the server? This can't be undone. Journeys on your PCs stay, and every PC stops syncing."
                  yes="Delete everything"
                  danger
                  onYes={act("data", deleteAccount)}
                  onNo={() => setAsking(null)}
                />
              ) : (
                <>
                  <div className="flex flex-1 flex-col gap-1">
                    <span className="text-sm font-medium">Delete everything</span>
                    <span className="text-xs leading-[1.45] text-muted">Removes your account and every journey from the server. Journeys on your PCs stay.</span>
                  </div>
                  <Button className={`${small} border-danger-line! text-danger!`} onClick={() => setAsking("delete")}>
                    Delete
                  </Button>
                </>
              )}
            </Row>
          </Card>
          {problem("data")}
        </Section>
      </div>
    </Shell>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="mx-1 text-xs font-medium text-faint">{title}</h2>
      {children}
    </section>
  );
}

function Card({ children }: { children: ReactNode }) {
  return <div className="flex flex-col rounded-[10px] border border-line bg-panel">{children}</div>;
}

// One row of a card; line draws the divider above it.
function Row({ line = false, children }: { line?: boolean; children: ReactNode }) {
  return (
    <>
      {line && <div className="mx-3.5 h-px bg-line-soft" />}
      <div className="flex items-center gap-3 px-3.5 py-3">{children}</div>
    </>
  );
}

// A question asked in the row itself, instead of a dialog the window would hide behind.
function Ask({ question, yes, danger = false, onYes, onNo }: { question: string; yes: string; danger?: boolean; onYes: () => void; onNo: () => void }) {
  return (
    <div className="flex flex-1 flex-col gap-2.5">
      <p className="text-[13px] leading-[1.45] text-[#c9c4d6]">{question}</p>
      <div className="flex gap-2">
        <Button look={danger ? "outline" : "cream"} className={danger ? "border-danger-line! text-danger!" : ""} onClick={onYes}>
          {yes}
        </Button>
        <Button onClick={onNo}>Cancel</Button>
      </div>
    </div>
  );
}
