// The delete page's script, built for the browser by link.ts and typechecked
// with the browser's types by tsconfig.page.json. Deleting needs a
// Battle.net sign-in made in the last few minutes (delete.ts), so an older
// one is asked to sign in again; the server checks it either way.
const $ = (id: string) => document.getElementById(id)!;
// A minute short of the server's 10, so a sign-in about to run out is renewed first.
const FRESH_MS = 9 * 60 * 1000;

type Session = { user: { name: string }; session: { createdAt: string } } | null;

async function signIn() {
  const r = await fetch("/api/auth/sign-in/social", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ provider: "battlenet", callbackURL: "/delete" }),
  }).catch(() => null);
  const data = (await r?.json().catch(() => null)) as { url?: string } | null;
  if (data?.url) location.href = data.url;
  else $("result").textContent = "That didn't work: the server couldn't be reached. Try again.";
}

function askToSignIn(why: string) {
  $("form").hidden = true;
  $("who").textContent = why;
  $("sign-in").hidden = false;
  $("sign-in").onclick = signIn;
}

const signedIn = (await fetch("/api/auth/get-session")
  .then((r) => (r.ok ? r.json() : null))
  .catch(() => null)) as Session;
if (!signedIn) {
  askToSignIn("Sign in with Battle.net to delete your account.");
} else if (Date.now() - Date.parse(signedIn.session.createdAt) > FRESH_MS) {
  askToSignIn(`Signed in as ${signedIn.user.name}. To delete, sign in with Battle.net again.`);
} else {
  $("who").textContent = `Signed in as ${signedIn.user.name}`;
  $("form").hidden = false;
  $("form").onsubmit = async (e) => {
    e.preventDefault();
    ($("delete") as HTMLButtonElement).disabled = true;
    const r = await fetch("/delete", { method: "POST" }).catch(() => null);
    const data = (await r?.json().catch(() => null)) as { error?: string } | null;
    ($("delete") as HTMLButtonElement).disabled = false;
    if (r?.ok) {
      $("form").hidden = true;
      $("who").textContent = "";
      $("result").textContent = "Deleted. Your account and journeys are gone from the server, and every PC has stopped syncing. You can close this page.";
    } else if (r?.status === 401) {
      askToSignIn(data?.error ?? "To delete, sign in with Battle.net again.");
    } else {
      $("result").textContent = `That didn't work: ${data?.error ?? "the server couldn't be reached."} Try again.`;
    }
  };
}
