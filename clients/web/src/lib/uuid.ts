/**
 * A random UUID, without requiring a secure context.
 *
 * `crypto.randomUUID()` is only defined on secure origins — HTTPS, or localhost. This app
 * is served over plain HTTP on a home network (`http://mercury:4851`), which is neither,
 * so calling it there throws. That is a particularly nasty failure because the call sites
 * are in constructors: one missing function took down the whole React tree and every page
 * rendered "This page couldn't load".
 *
 * `crypto.getRandomValues` carries no such restriction, so the identifier is assembled from
 * it directly, in the version-4 layout the hub expects for a session id.
 */
export function randomUUID(): string {
  const native = globalThis.crypto;

  if (typeof native?.randomUUID === "function") {
    return native.randomUUID();
  }

  if (typeof native?.getRandomValues === "function") {
    const bytes = native.getRandomValues(new Uint8Array(16));
    // Version 4, variant 1 — the bits a parser checks before accepting the rest.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0"));
    return [
      hex.slice(0, 4).join(""),
      hex.slice(4, 6).join(""),
      hex.slice(6, 8).join(""),
      hex.slice(8, 10).join(""),
      hex.slice(10, 16).join(""),
    ].join("-");
  }

  // No crypto at all is not a real browser, but an id that is merely unlikely to collide
  // still beats throwing on a listening session that nobody's security depends on.
  const random = () =>
    Math.floor(Math.random() * 0x10000)
      .toString(16)
      .padStart(4, "0");
  return `${random()}${random()}-${random()}-4${random().slice(1)}-a${random().slice(1)}-${random()}${random()}${random()}`;
}
