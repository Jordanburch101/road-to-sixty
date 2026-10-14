// Everything the window asks of the app. The names and shapes match
// src-tauri/src/commands.rs, account.rs, update.rs and status.rs; the
// server's answers are typed by @road-to-sixty/api.
import type { CharacterInfo, DeviceInfo, RestoreResponse, VersionInfo } from "@road-to-sixty/api";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { disable, enable, isEnabled } from "@tauri-apps/plugin-autostart";
import { useEffect, useState } from "react";

export const isMac = navigator.userAgent.includes("Mac");

export type Game = { path: string; name: string; addon: string | null; characters: number };
export type Character = {
  key: string;
  here: boolean;
  updateAddon: boolean;
  uploaded: number | null;
  problem: string | null; // why it isn't backed up
  note: string;
};
export type Update =
  | { state: "none" }
  | { state: "ready"; version: string }
  | { state: "updated"; version: string; at: number }
  | { state: "failed"; why: string };
export type Status = {
  linkedTo: string | null;
  pc: string | null;
  version: string;
  games: Game[];
  characters: Character[];
  lastSynced: number | null;
  paused: boolean;
  offline: boolean;
  problems: string[];
  linkCode: string | null;
  line: string;
  update: Update;
};

export const getStatus = () => invoke<Status>("status");
export const onStatus = (show: (s: Status) => void) => listen<Status>("status", (e) => show(e.payload));
export const hostName = () => invoke<string>("host_name");
export const link = (name: string) => invoke("link", { name });
export const unlink = () => invoke("unlink");
export const setPaused = (paused: boolean) => invoke("set_paused", { paused });
export const pickFolder = () => invoke("pick_folder");

export const characters = () => invoke<CharacterInfo[]>("characters");
export const versions = (id: number) => invoke<VersionInfo[]>("versions", { id });
export const restore = (id: number, version: number) => invoke<RestoreResponse>("restore", { id, version });
export const devices = () => invoke<DeviceInfo[]>("devices");
export const renameDevice = (id: string, name: string) => invoke<DeviceInfo>("rename_device", { id, name });
export const unlinkDevice = (id: string) => invoke("unlink_device", { id });
export const exportData = () => invoke<boolean>("export_data");
export const deleteAccount = () => invoke("delete_account");

export const startsAtLogin = () => isEnabled();
export const setStartsAtLogin = (on: boolean) => (on ? enable() : disable());
export const checkUpdate = () => invoke<string | null>("check_update");
export const installUpdate = () => invoke("install_update");

// Loads from the server through the app, and again whenever deps change or
// reload is called. error is the reason, in words.
export function useLoad<T>(load: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [n, setN] = useState(0);
  useEffect(() => {
    let live = true;
    load().then(
      (d) => live && (setData(d), setError(null)),
      (e) => live && setError(String(e)),
    );
    return () => {
      live = false;
    };
  }, [...deps, n]);
  return { data, error, reload: () => setN((x) => x + 1) };
}
