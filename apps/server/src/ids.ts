// A row id from a request (a path or query value, or a JSON field): a
// whole number above 0 that both JavaScript and Postgres's bigint hold
// exactly, or null. Passed on unchecked, "abc", 1.5 or a long run of digits
// fails in the query instead, as a server error.
export function rowId(value: unknown): number | null {
  const text = typeof value === "number" ? String(value) : value;
  if (typeof text !== "string" || !/^[1-9]\d{0,15}$/.test(text)) return null;
  const n = Number(text);
  return Number.isSafeInteger(n) ? n : null;
}
