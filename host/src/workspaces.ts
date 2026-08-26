import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  accessSync,
  constants,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { promisify } from "node:util";
import { agentDir } from "./token.js";

const execFileAsync = promisify(execFile);
const registryPath = join(agentDir, "tmux-session-tree.json");
const workspacePath = join(agentDir, "tmux-workspaces.json");
const launchDirectory = join(agentDir, "vipi", "launches");
const browserRoot = canonicalDirectory(process.env.VIPI_WORKSPACE_ROOT ?? homedir());

interface RawRegistryEntry {
  piSessionId?: string;
  sessionFile?: string;
  name?: string;
  topic?: string;
  named?: boolean;
  status?: "idle" | "working";
  unread?: boolean;
  cwd?: string;
  tmuxSession?: string;
  tmuxWindow?: string;
  tmuxPaneId?: string;
  pid?: number;
  createdAt?: string;
  lastSeen?: string;
}

export interface WorkspaceListResult {
  home: string;
  workspaces: string[];
}

export interface WorkspaceBrowseResult {
  path: string;
  parent?: string;
  directories: string[];
}

export interface SessionLaunchResult {
  cwd: string;
  paneID: string;
}

function canonicalDirectory(path: string): string {
  const canonical = realpathSync(resolve(path));
  if (!statSync(canonical).isDirectory()) throw new Error("The selected path is not a directory.");
  return canonical;
}

function inside(root: string, candidate: string): boolean {
  const value = relative(root, candidate);
  return value === "" || (value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value));
}

function readJSON(path: string): Record<string, unknown> {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return value && typeof value === "object" ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function atomicWrite(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporary = `${path}.vipi-${process.pid}-${randomUUID()}`;
  try {
    writeFileSync(temporary, JSON.stringify(value, null, 2), { mode: 0o600 });
    renameSync(temporary, path);
  } finally {
    try { unlinkSync(temporary); } catch {}
  }
}

export function registeredWorkspaces(): string[] {
  const value = readJSON(workspacePath).workspaces;
  if (!Array.isArray(value)) return [];
  const unique = new Set<string>();
  for (const candidate of value) {
    if (typeof candidate !== "string") continue;
    try { unique.add(canonicalDirectory(candidate)); } catch {}
  }
  return [...unique].sort((left, right) => left.localeCompare(right));
}

function allowedRoots(): string[] {
  return [browserRoot, ...registeredWorkspaces()].filter((value, index, values) => values.indexOf(value) === index);
}

function validatedDirectory(requestedPath: unknown): string {
  const requested = typeof requestedPath === "string" && requestedPath.trim() ? requestedPath.trim() : browserRoot;
  if (requested.length > 2_048 || !isAbsolute(requested)) throw new Error("Choose a valid absolute directory.");
  const canonical = canonicalDirectory(requested);
  if (!allowedRoots().some((root) => inside(root, canonical))) throw new Error("That directory is outside the allowed workspace roots.");
  return canonical;
}

export function listWorkspaces(): WorkspaceListResult {
  return { home: browserRoot, workspaces: registeredWorkspaces() };
}

export function browseWorkspace(requestedPath: unknown): WorkspaceBrowseResult {
  const path = validatedDirectory(requestedPath);
  const roots = allowedRoots();
  const children = Array.from(new Set(
    // Resolve symlinks before returning anything to the mobile client.
    readdirSync(path, { withFileTypes: true }).flatMap((entry): string[] => {
      if (entry.name.startsWith(".") || entry.name === "node_modules") return [];
      const unresolved = join(path, entry.name);
      try {
        if (!entry.isDirectory() && !entry.isSymbolicLink()) return [];
        const canonical = canonicalDirectory(unresolved);
        return roots.some((root) => inside(root, canonical)) ? [canonical] : [];
      } catch { return []; }
    }),
  )).sort((left, right) => basename(left).localeCompare(basename(right), undefined, { sensitivity: "base" })).slice(0, 250);

  const parentCandidate = dirname(path);
  const parent = parentCandidate !== path && roots.some((root) => inside(root, parentCandidate))
    ? parentCandidate
    : undefined;
  return { path, ...(parent ? { parent } : {}), directories: children };
}

function registerWorkspace(path: string): void {
  const workspaces = registeredWorkspaces();
  if (!workspaces.includes(path)) workspaces.push(path);
  workspaces.sort((left, right) => left.localeCompare(right));
  atomicWrite(workspacePath, { workspaces });
}

function executable(name: string, override?: string): string {
  if (override) {
    accessSync(override, constants.X_OK);
    return override;
  }
  for (const directory of (process.env.PATH ?? "").split(":")) {
    if (!directory) continue;
    const candidate = join(directory, name);
    try { accessSync(candidate, constants.X_OK); return candidate; } catch {}
  }
  for (const candidate of [`/opt/homebrew/bin/${name}`, `/usr/local/bin/${name}`, `/usr/bin/${name}`]) {
    try { accessSync(candidate, constants.X_OK); return candidate; } catch {}
  }
  throw new Error(`${name} is not installed on the Vipi host.`);
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/gu, `'"'"'`)}'`;
}

async function tmuxSession(tmux: string): Promise<string | undefined> {
  if (process.env.VIPI_TMUX_SESSION) return process.env.VIPI_TMUX_SESSION;
  try {
    const { stdout } = await execFileAsync(tmux, [
      "list-sessions", "-F", "#{session_name}\t#{session_attached}\t#{session_created}",
    ], { timeout: 5_000 });
    const sessions = stdout.split("\n").flatMap((line): Array<{ name: string; attached: number; created: number }> => {
      const [name, attachedValue, createdValue] = line.split("\t");
      const attached = Number(attachedValue);
      const created = Number(createdValue);
      return name && Number.isFinite(attached) && Number.isFinite(created) ? [{ name, attached, created }] : [];
    });
    sessions.sort((left, right) => right.attached - left.attached || right.created - left.created);
    return sessions[0]?.name;
  } catch {
    return undefined;
  }
}

function addPendingRegistryEntry(result: string, cwd: string): string {
  const [tmuxSession, tmuxWindow, paneID, pidValue] = result.trim().split("\t");
  const pid = Number(pidValue);
  if (!tmuxSession || !tmuxWindow || !paneID?.startsWith("%") || !Number.isFinite(pid)) {
    throw new Error("tmux did not return a valid Pi pane.");
  }
  const body = readJSON(registryPath);
  const entries = Array.isArray(body.entries) ? body.entries.filter((value): value is RawRegistryEntry => Boolean(value && typeof value === "object")) : [];
  const now = new Date().toISOString();
  const pending: RawRegistryEntry = {
    piSessionId: `pending:${paneID}`,
    named: false,
    status: "idle",
    unread: false,
    cwd,
    tmuxSession,
    tmuxWindow,
    tmuxPaneId: paneID,
    pid,
    createdAt: now,
    lastSeen: now,
  };
  const existingIndex = entries.findIndex((entry) => entry.tmuxPaneId === paneID);
  if (existingIndex >= 0) entries[existingIndex] = pending; else entries.push(pending);
  atomicWrite(registryPath, { ...body, entries });
  return paneID;
}

export async function launchSession(requestedPath: unknown): Promise<SessionLaunchResult> {
  const cwd = validatedDirectory(requestedPath);
  const tmux = executable("tmux", process.env.VIPI_TMUX_EXECUTABLE);
  const pi = executable("pi", process.env.VIPI_PI_EXECUTABLE);
  mkdirSync(launchDirectory, { recursive: true, mode: 0o700 });
  const gate = join(launchDirectory, `${randomUUID()}.ready`);
  const command = `while [ ! -f ${shellQuote(gate)} ]; do sleep 0.02; done; exec ${shellQuote(pi)} --tui-mode regular`;
  const session = await tmuxSession(tmux);

  let stdout: string;
  if (session) {
    ({ stdout } = await execFileAsync(tmux, [
      "new-window", "-d", "-P", "-F", "#S\t#I\t#{pane_id}\t#{pane_pid}",
      "-t", `${session}:`, "-c", cwd, "-n", "pi-new", command,
    ], { timeout: 8_000 }));
  } else {
    const name = `vipi-${Date.now().toString(36)}`;
    ({ stdout } = await execFileAsync(tmux, [
      "new-session", "-d", "-P", "-F", "#S\t#I\t#{pane_id}\t#{pane_pid}",
      "-s", name, "-c", cwd, "-n", "pi-new", command,
    ], { timeout: 8_000 }));
  }

  try {
    registerWorkspace(cwd);
    const paneID = addPendingRegistryEntry(stdout, cwd);
    writeFileSync(gate, "ready\n", { mode: 0o600 });
    setTimeout(() => { try { unlinkSync(gate); } catch {} }, 5_000).unref();
    return { cwd, paneID };
  } catch (error) {
    try { unlinkSync(gate); } catch {}
    const paneID = stdout.trim().split("\t")[2];
    if (paneID?.startsWith("%")) {
      try { await execFileAsync(tmux, ["kill-pane", "-t", paneID], { timeout: 3_000 }); } catch {}
    }
    throw error;
  }
}
