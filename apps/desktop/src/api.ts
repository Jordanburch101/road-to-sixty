// Everything the window asks of the app. The names and shapes match
// src-tauri/src/commands.rs and status.rs.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { confirm } from "@tauri-apps/plugin-dialog";

// Only a Mac draws its window buttons over the window; Windows has a title bar.
export const isMac = navigator.userAgent.includes("Mac");

export type Game = { path: string; name: string; addon: string | null };
export type Character = {
  key: string;
  here: boolean;
  updateAddon: boolean;
  uploaded: number | null;
  problem: string | null; // why it isn't backed up
  note: string;
};
export type Status = {
  linkedTo: string | null;
  games: Game[];
  characters: Character[];
  lastSynced: number | null;
  paused: boolean;
  offline: boolean;
  problems: string[];
  linkCode: string | null;
  line: string;
};

export const getStatus = () => invoke<Status>("status");
export const onStatus = (show: (s: Status) => void) => listen<Status>("status", (e) => show(e.payload));
export const link = () => invoke("link", { name: "" });
export const setPaused = (paused: boolean) => invoke("set_paused", { paused });

export async function unlink() {
  const sure = await confirm("Syncing stops on this PC. Your journeys stay here and on the server.", { title: "Unlink this PC?", kind: "warning" });
  if (sure) await invoke("unlink");
}

export const addFolder = () => invoke("pick_folder");

export const startsAtLogin = () => isEnabled();
export const setStartsAtLogin = (on: boolean) => (on ? enable() : disable());
export const checkUpdate = () => invoke<string | null>("check_update");
export const installUpdate = () => invoke("install_update");
