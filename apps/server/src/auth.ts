import { APP_CLIENT_ID } from "@road-to-sixty/api";
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer } from "better-auth/plugins/bearer";
import { deviceAuthorization } from "better-auth/plugins/device-authorization";
import { genericOAuth } from "better-auth/plugins/generic-oauth";
import { config } from "./config";
import { db } from "./db";
import { signUps } from "./limits";
import { TRUSTED_PROXIES } from "./proxies";
import * as schema from "./schema";

// The Battle.net account ID, kept only as a keyed hash (spec, "Privacy").
export function accountHash(id: string | number): string {
  return new Bun.CryptoHasher("sha256", config.auth.accountHashKey).update(String(id)).digest("hex");
}

// The account ID from Battle.net's userinfo, or "" when the reply names
// none. Better Auth refuses an empty account subject; a hash of nothing
// would put every such player in one account.
function battlenetId(profile: { id?: string | number | null; sub?: string | number | null }): string {
  return String(profile.id ?? profile.sub ?? "");
}

export const auth = betterAuth({
  baseURL: config.auth.url,
  secret: config.auth.secret,
  database: drizzleAdapter(db, { provider: "pg", schema }),
  // Each call for a link code makes a database row, and needs no account.
  rateLimit: { customRules: { "/device/code": { window: 60, max: 10 } } },
  advanced: {
    // Rate limits count by visitor (see proxies.ts). If Dokploy's proxy
    // leaves only Cloudflare's address in X-Forwarded-For, Cloudflare's own
    // header names the visitor; it is read only when X-Forwarded-For gives
    // no visitor, so a direct caller can't use it.
    ipAddress: { trustedProxies: TRUSTED_PROXIES, ipAddressHeaders: ["x-forwarded-for", "cf-connecting-ip"] },
  },
  databaseHooks: {
    // Battle.net accounts are free, so new players come in at a steady rate.
    user: { create: { before: async () => (signUps.take("all") ? undefined : false) } },
    // The spec's privacy list has no IP addresses or browser details.
    session: { create: { before: async (session) => ({ data: { ...session, ipAddress: null, userAgent: null } }) } },
    account: {
      // Sign-in needs Battle.net's tokens only once, to read who signed in.
      create: { before: async (account) => ({ data: { ...account, accessToken: null, refreshToken: null, idToken: null } }) },
      update: { before: async (account) => ({ data: { ...account, accessToken: null, refreshToken: null, idToken: null } }) },
    },
  },
  plugins: [
    genericOAuth({
      config: [
        {
          providerId: "battlenet",
          name: "Battle.net",
          authorizationUrl: `${config.battlenet.url}/authorize`,
          tokenUrl: `${config.battlenet.url}/token`,
          userInfoUrl: `${config.battlenet.url}/userinfo`,
          clientId: config.battlenet.clientId,
          clientSecret: config.battlenet.clientSecret,
          scopes: ["openid"],
          accountSubject: ({ profile }) => {
            // Blizzard documents sub and id as the same account ID, but
            // libraries disagree (spec, "Risks"). Accounts are keyed by id.
            if (profile.sub != null && profile.id != null && String(profile.sub) !== String(profile.id)) {
              console.warn("battle.net: sub and id differ; accounts are keyed by id");
            }
            const id = battlenetId(profile);
            return id && accountHash(id);
          },
          // Battle.net gives no email, and Better Auth needs one per user:
          // an address that can never receive mail, unique to the account.
          mapProfileToUser: (profile) => ({
            name: String(profile.battletag ?? "Player"),
            email: `${accountHash(battlenetId(profile))}@battlenet.invalid`,
            emailVerified: false,
          }),
          // The BattleTag can change; Blizzard's terms want it kept current.
          overrideUserInfo: true,
        },
      ],
    }),
    deviceAuthorization({
      verificationUri: "/link",
      validateClient: (clientId) => clientId === APP_CLIENT_ID,
    }),
    bearer(),
  ],
});
