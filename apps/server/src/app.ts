import { Elysia } from "elysia";
import { auth } from "./auth";
import { link } from "./link";
import { sync } from "./sync";

export const app = new Elysia()
  .get("/health", () => "ok")
  // Better Auth reads the request itself, so Elysia must leave the body alone.
  .all("/api/auth/*", ({ request }) => auth.handler(request), { parse: "none" })
  .use(link)
  .use(sync);
