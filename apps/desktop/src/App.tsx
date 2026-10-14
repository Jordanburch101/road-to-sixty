import { useEffect, useState } from "react";
import { getStatus, onStatus, type Status } from "./api";
import { Account } from "./Account";
import { Characters, type Tab } from "./Characters";
import { FirstRun } from "./FirstRun";

export function App() {
  const [status, setStatus] = useState<Status | null>(null);
  // Linking finishes on step 2; step 3 (restart WoW) stays up until Done.
  const [restartStep, setRestartStep] = useState(false);
  const [tab, setTab] = useState<Tab>("characters");

  useEffect(() => {
    getStatus().then(setStatus);
    const stop = onStatus(setStatus);
    return () => void stop.then((unlisten) => unlisten());
  }, []);
  useEffect(() => {
    if (status?.linkCode) setRestartStep(true);
  }, [status?.linkCode]);

  if (!status) return null;
  if (!status.linkedTo || restartStep) return <FirstRun status={status} onDone={() => setRestartStep(false)} />;
  return tab === "characters" ? <Characters status={status} onTab={setTab} /> : <Account status={status} onTab={setTab} />;
}
