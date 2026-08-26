import { createSign } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { connect } from "node:http2";
import { dirname, join, resolve } from "node:path";
import { agentDir } from "./token.js";

export type APNsEnvironment = "sandbox" | "production";

type PushDevice = {
  token: string;
  environment: APNsEnvironment;
  updatedAt: string;
};

type DeviceRegistry = { devices: PushDevice[] };

const registryPath = join(agentDir, "vipi", "apns-devices.json");
const configurationPath = join(agentDir, "vipi", "apns.json");
const defaultTopic = "com.abovetech.vipi.choijuwon";
let cachedProviderToken: { value: string; issuedAt: number } | undefined;

function readRegistry(): DeviceRegistry {
  try {
    const value = JSON.parse(readFileSync(registryPath, "utf8")) as Partial<DeviceRegistry>;
    const devices = Array.isArray(value.devices) ? value.devices.filter((device): device is PushDevice => (
      Boolean(device) &&
      typeof device.token === "string" && /^[a-f0-9]{64,200}$/u.test(device.token) &&
      (device.environment === "sandbox" || device.environment === "production") &&
      typeof device.updatedAt === "string"
    )) : [];
    return { devices };
  } catch {
    return { devices: [] };
  }
}

function saveRegistry(registry: DeviceRegistry): void {
  mkdirSync(dirname(registryPath), { recursive: true, mode: 0o700 });
  const temporary = `${registryPath}.tmp-${process.pid}-${Date.now()}`;
  try {
    writeFileSync(temporary, JSON.stringify(registry, null, 2), { mode: 0o600 });
    renameSync(temporary, registryPath);
  } finally {
    try { unlinkSync(temporary); } catch {}
  }
}

export function registerPushDevice(tokenValue: unknown, environmentValue: unknown): PushDevice {
  const token = typeof tokenValue === "string" ? tokenValue.trim().toLowerCase() : "";
  const environment = environmentValue === "production" ? "production" : environmentValue === "sandbox" ? "sandbox" : undefined;
  if (!/^[a-f0-9]{64,200}$/u.test(token) || !environment) throw new Error("The APNs device token is invalid.");
  const device: PushDevice = { token, environment, updatedAt: new Date().toISOString() };
  const registry = readRegistry();
  registry.devices = registry.devices.filter((candidate) => candidate.token !== token);
  registry.devices.push(device);
  saveRegistry(registry);
  return device;
}

export function unregisterPushDevice(tokenValue: unknown): boolean {
  const token = typeof tokenValue === "string" ? tokenValue.trim().toLowerCase() : "";
  if (!token) return false;
  const registry = readRegistry();
  const next = registry.devices.filter((candidate) => candidate.token !== token);
  if (next.length === registry.devices.length) return false;
  saveRegistry({ devices: next });
  return true;
}

function credentialConfiguration(): {
  keyPath: string;
  keyID: string;
  teamID: string;
  topic: string;
} | undefined {
  let file: Record<string, unknown> = {};
  try {
    const value = JSON.parse(readFileSync(configurationPath, "utf8"));
    if (value && typeof value === "object") file = value as Record<string, unknown>;
  } catch {}
  const keyPathValue = process.env.VIPI_APNS_KEY_PATH ?? (typeof file.keyPath === "string" ? file.keyPath : undefined);
  const keyID = process.env.VIPI_APNS_KEY_ID ?? (typeof file.keyID === "string" ? file.keyID : undefined);
  const teamID = process.env.VIPI_APNS_TEAM_ID ?? (typeof file.teamID === "string" ? file.teamID : undefined);
  if (!keyPathValue || !keyID || !teamID) return undefined;
  const keyPath = resolve(keyPathValue.replace(/^~(?=\/)/u, process.env.HOME ?? ""));
  if (!existsSync(keyPath) || !/^[A-Z0-9]{10}$/u.test(keyID) || !/^[A-Z0-9]{10}$/u.test(teamID)) return undefined;
  const fileTopic = typeof file.topic === "string" ? file.topic : undefined;
  return { keyPath, keyID, teamID, topic: process.env.VIPI_APNS_TOPIC ?? fileTopic ?? defaultTopic };
}

export function pushStatus(): { configured: boolean; devices: number; topic: string } {
  const configuration = credentialConfiguration();
  return {
    configured: Boolean(configuration),
    devices: readRegistry().devices.length,
    topic: configuration?.topic ?? process.env.VIPI_APNS_TOPIC ?? defaultTopic,
  };
}

function base64URL(value: Buffer | string): string {
  return Buffer.from(value).toString("base64url");
}

function providerToken(): string {
  const configuration = credentialConfiguration();
  if (!configuration) throw new Error("APNs credentials are not configured.");
  const now = Math.floor(Date.now() / 1_000);
  if (cachedProviderToken && now - cachedProviderToken.issuedAt < 50 * 60) return cachedProviderToken.value;
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: configuration.keyID }));
  const claims = base64URL(JSON.stringify({ iss: configuration.teamID, iat: now }));
  const signingInput = `${header}.${claims}`;
  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({ key: readFileSync(configuration.keyPath, "utf8"), dsaEncoding: "ieee-p1363" });
  const value = `${signingInput}.${base64URL(signature)}`;
  cachedProviderToken = { value, issuedAt: now };
  return value;
}

async function sendToDevice(
  device: PushDevice,
  payload: Buffer,
): Promise<{ status: number; reason?: string }> {
  const configuration = credentialConfiguration();
  if (!configuration) return { status: 0, reason: "NOT_CONFIGURED" };
  const origin = device.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  let authorization: string;
  try { authorization = `bearer ${providerToken()}`; }
  catch { return { status: 0, reason: "INVALID_CREDENTIALS" }; }

  return new Promise((resolveResult) => {
    const client = connect(origin);
    let settled = false;
    const finish = (result: { status: number; reason?: string }) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { client.close(); } catch {}
      resolveResult(result);
    };
    const timer = setTimeout(() => finish({ status: 0, reason: "TIMEOUT" }), 8_000);
    client.once("error", () => finish({ status: 0, reason: "CONNECTION_FAILED" }));
    const request = client.request({
      ":method": "POST",
      ":path": `/3/device/${device.token}`,
      authorization,
      "apns-topic": configuration.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
      "content-length": String(payload.length),
    });
    let status = 0;
    const chunks: Buffer[] = [];
    request.on("response", (headers) => { status = Number(headers[":status"] ?? 0); });
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("error", () => finish({ status: 0, reason: "REQUEST_FAILED" }));
    request.on("end", () => {
      let reason: string | undefined;
      try { reason = JSON.parse(Buffer.concat(chunks).toString("utf8")).reason; } catch {}
      finish({ status, ...(reason ? { reason } : {}) });
    });
    request.end(payload);
  });
}

export async function sendSessionCompletedPush(session: { id: string; name: string }): Promise<void> {
  if (!credentialConfiguration()) return;
  const registry = readRegistry();
  if (registry.devices.length === 0) return;
  const payload = Buffer.from(JSON.stringify({
    aps: {
      alert: {
        title: session.name || "Vipi",
        body: "Pi finished responding.",
      },
      sound: "default",
      "thread-id": `session-${session.id}`,
    },
    sessionID: session.id,
  }));
  const results = await Promise.all(registry.devices.map(async (device) => ({
    device,
    result: await sendToDevice(device, payload),
  })));
  const invalid = new Set(results.filter(({ result }) => result.status === 410).map(({ device }) => device.token));
  if (invalid.size > 0) saveRegistry({ devices: registry.devices.filter((device) => !invalid.has(device.token)) });
}
