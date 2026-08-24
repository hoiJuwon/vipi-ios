export interface PairingPayload {
  host: string;
  token: string;
}

export function createPairingPayload(publicURL: string | undefined, token: string): PairingPayload {
  if (!publicURL) {
    throw new Error("VIPI_PUBLIC_URL is required for pairing QR output (for example https://mac.tailnet-name.ts.net)");
  }
  let url: URL;
  try { url = new URL(publicURL); }
  catch { throw new Error("VIPI_PUBLIC_URL must be a valid HTTPS Tailscale URL"); }
  if (url.protocol !== "https:" || !url.hostname.toLowerCase().endsWith(".ts.net")) {
    throw new Error("VIPI_PUBLIC_URL must use HTTPS and a .ts.net Tailscale hostname");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("VIPI_PUBLIC_URL must not contain credentials, query parameters, or fragments");
  }
  const path = url.pathname === "/" ? "" : url.pathname.replace(/\/$/, "");
  return { host: `${url.origin}${path}`, token };
}
