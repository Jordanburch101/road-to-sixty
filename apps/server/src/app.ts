import { Elysia } from "elysia";
import { sync } from "./sync";

export const app = new Elysia().get("/health", () => "ok").use(sync);
