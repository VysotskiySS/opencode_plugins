#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/go-usage"
PLUGIN_PATH="$PLUGIN_DIR/tui.tsx"
TUI_CONFIG="$CONFIG_DIR/tui.json"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"

mkdir -p "$PLUGIN_DIR"

cat > "$PLUGIN_DIR/package.json" <<'PACKAGE_EOF'
{
  "name": "opencode-go-usage",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "oc-plugin": ["tui"],
  "exports": {
    "./tui": "./tui.tsx"
  },
  "peerDependencies": {
    "@opencode-ai/plugin": "^1.0.0"
  },
  "dependencies": {
    "@opentui/core": "0.4.5",
    "@opentui/solid": "0.4.5",
    "solid-js": "1.9.12"
  }
}
PACKAGE_EOF

cat > "$PLUGIN_PATH" <<'TUI_EOF'
/** @jsxImportSource @opentui/solid */
import { For, Show, createSignal } from "solid-js"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { Database } from "bun:sqlite"

const LEGACY_USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
const CONSOLE_URL = "https://opencode.ai/console"
const REFRESH_MS = 120_000
const BAR_WIDTH = 10

const WINDOWS: ReadonlyArray<{ key: string; label: string }> = [
  { key: "rolling", label: "5h" },
  { key: "weekly", label: "wk" },
  { key: "monthly", label: "mo" },
]

interface UsageWindow {
  percent?: number
  resetsAt?: string
}

interface Usage {
  rolling?: UsageWindow
  weekly?: UsageWindow
  monthly?: UsageWindow
}

type Status = "loading" | "ok" | "nokey" | "nogo" | "relogin" | "error"

interface WidgetState {
  status: Status
  usage?: Usage
  error?: string
}

interface ConsoleAccount {
  token: string
  orgID?: string
  url: string
}

interface ConsoleMeter {
  usedMicroCents?: string | number
  limitMicroCents?: string | number
  resetsAt?: string
}

interface ConsoleStatusBody {
  product?: string | null
  access?: {
    meters?: {
      fiveHour?: ConsoleMeter
      week?: ConsoleMeter
      month?: ConsoleMeter
    }
  } | null
}

class HttpStatusError extends Error {
  constructor(readonly status: number) {
    super(`HTTP ${status}`)
  }
}

class NoGoSubscriptionError extends Error {}

function opencodeDataDir(): string {
  const dataHome = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share")
  return join(dataHome, "opencode")
}

function readConsoleAccount(): ConsoleAccount | undefined {
  let db: Database | undefined
  try {
    db = new Database(join(opencodeDataDir(), "opencode.db"), { readonly: true })
    const row = db
      .query(
        `SELECT a.access_token AS token, a.url AS url, s.active_org_id AS orgID
         FROM account_state s
         JOIN account a ON a.id = s.active_account_id
         WHERE s.active_account_id IS NOT NULL
         LIMIT 1`,
      )
      .get() as { token?: string; url?: string; orgID?: string | null } | null
    if (row?.token) {
      return { token: row.token, orgID: row.orgID ?? undefined, url: row.url || CONSOLE_URL }
    }
    const legacy = db
      .query(`SELECT access_token AS token, url FROM control_account WHERE active = 1 LIMIT 1`)
      .get() as { token?: string; url?: string } | null
    if (legacy?.token) return { token: legacy.token, url: legacy.url || CONSOLE_URL }
  } catch {
    // opencode.db missing, locked or on an older schema - fall through
  } finally {
    db?.close()
  }
  return undefined
}

function readAuthKey(): string | undefined {
  try {
    const data = JSON.parse(readFileSync(join(opencodeDataDir(), "auth.json"), "utf8"))
    for (const id of ["opencode-go", "opencode"]) {
      const entry = data?.[id]
      if (entry?.key) return String(entry.key)
      if (entry?.access) return String(entry.access)
    }
  } catch {
    // auth.json missing or unreadable - fall through
  }
  return undefined
}

function consoleHeaders(token: string, orgID: string | undefined, version: string): Record<string, string> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${token}`,
    accept: "application/json",
    "user-agent": `opencode/${version}`,
  }
  if (orgID) headers["x-org-id"] = orgID
  return headers
}

function consoleBase(account: ConsoleAccount): string {
  return account.url.replace(/\/+$/, "")
}

async function resolveOrgID(account: ConsoleAccount, version: string): Promise<string | undefined> {
  const res = await fetch(`${consoleBase(account)}/api/orgs`, {
    headers: consoleHeaders(account.token, undefined, version),
  })
  if (!res.ok) return undefined
  const orgs = (await res.json()) as Array<{ id?: string }>
  return orgs[0]?.id
}

function percentFromMeter(meter?: ConsoleMeter): number {
  if (!meter) return 0
  const used = Number(meter.usedMicroCents ?? 0)
  const limit = Number(meter.limitMicroCents ?? 0)
  if (!Number.isFinite(used) || !Number.isFinite(limit) || limit <= 0) return 0
  return Math.min(100, Math.max(0, (used / limit) * 100))
}

function windowFromMeter(meter?: ConsoleMeter): UsageWindow | undefined {
  if (!meter) return undefined
  return { percent: percentFromMeter(meter), resetsAt: meter.resetsAt }
}

async function fetchConsoleUsage(account: ConsoleAccount, version: string): Promise<Usage> {
  if (!account.orgID) account.orgID = await resolveOrgID(account, version)
  const res = await fetch(`${consoleBase(account)}/api/go/status`, {
    headers: consoleHeaders(account.token, account.orgID, version),
  })
  if (!res.ok) throw new HttpStatusError(res.status)
  const body = (await res.json()) as ConsoleStatusBody
  const meters = body.access?.meters
  if (!meters) throw new NoGoSubscriptionError()
  return {
    rolling: windowFromMeter(meters.fiveHour),
    weekly: windowFromMeter(meters.week),
    monthly: windowFromMeter(meters.month),
  }
}

async function fetchLegacyUsage(key: string): Promise<Usage> {
  const res = await fetch(LEGACY_USAGE_URL, {
    headers: { authorization: `Bearer ${key}`, accept: "application/json" },
  })
  if (!res.ok) throw new HttpStatusError(res.status)
  const body: { usage?: Usage } = await res.json()
  return body.usage ?? {}
}

function bar(percent: number): string {
  const clamped = Math.min(100, Math.max(0, percent))
  const filled = Math.round((clamped / 100) * BAR_WIDTH)
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled)
}

function countdown(iso?: string): string {
  if (!iso) return ""
  const ms = new Date(iso).getTime() - Date.now()
  if (!Number.isFinite(ms) || ms <= 0) return "now"
  const minutes = Math.floor(ms / 60_000)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}

function highest(usage: Usage | undefined): number {
  if (!usage) return 0
  return Math.max(0, ...WINDOWS.map((w) => usage[w.key as keyof Usage]?.percent ?? 0))
}

// DeepSeek peak/off-peak billing: peak = weekdays 01:00-04:00 and 06:00-10:00 UTC,
// off-peak = every other hour and all weekend, at 50% of the peak rate.
function isDeepseekPeak(date: Date): boolean {
  const day = date.getUTCDay()
  if (day === 0 || day === 6) return false
  const minutes = date.getUTCHours() * 60 + date.getUTCMinutes()
  return (minutes >= 60 && minutes < 240) || (minutes >= 360 && minutes < 600)
}

function msUntilTariffChange(from: Date): number {
  const cursor = new Date(from.getTime())
  cursor.setUTCSeconds(0, 0)
  const initial = isDeepseekPeak(from)
  for (let i = 1; i <= 8 * 24 * 60; i++) {
    cursor.setUTCMinutes(cursor.getUTCMinutes() + 1)
    if (isDeepseekPeak(cursor) !== initial) return cursor.getTime() - from.getTime()
  }
  return 0
}

function shortDuration(ms: number): string {
  const totalMinutes = Math.max(0, Math.round(ms / 60_000))
  const days = Math.floor(totalMinutes / 1440)
  const hours = Math.floor((totalMinutes % 1440) / 60)
  const minutes = totalMinutes % 60
  if (days > 0) return `${days}d ${hours}h`
  if (hours > 0) return `${hours}h ${minutes}m`
  return `${minutes}m`
}

const tui = async (api: any, options?: { apiKey?: string }) => {
  const [state, setState] = createSignal<WidgetState>({ status: "loading" })
  let disposed = false
  const version = String(api.app?.version ?? "unknown")

  const fail = (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error)
    const status: Status =
      error instanceof HttpStatusError && error.status === 401
        ? "relogin"
        : error instanceof NoGoSubscriptionError ||
            (error instanceof HttpStatusError && (error.status === 403 || error.status === 404))
          ? "nogo"
          : "error"
    if (!disposed) {
      setState((prev) => ({ status, usage: status === "nogo" ? undefined : prev.usage, error: message }))
    }
  }

  const refresh = async () => {
    const account = readConsoleAccount()
    if (account) {
      try {
        const usage = await fetchConsoleUsage(account, version)
        if (!disposed) setState({ status: "ok", usage })
      } catch (error) {
        fail(error)
      }
      return
    }

    const key = options?.apiKey || process.env.OPENCODE_API_KEY || readAuthKey()
    if (!key) {
      if (!disposed) setState({ status: "nokey" })
      return
    }
    try {
      const usage = await fetchLegacyUsage(key)
      if (!disposed) setState({ status: "ok", usage })
    } catch (error) {
      fail(error)
    }
  }

  void refresh()
  const timer = setInterval(() => void refresh(), REFRESH_MS)
  api.lifecycle?.onDispose?.(() => {
    disposed = true
    clearInterval(timer)
  })

  api.slots.register({
    order: 150,
    slots: {
      sidebar_content(ctx: { theme: { current: Record<string, unknown> } }) {
        const snapshot = state()
        const theme = ctx.theme.current as Record<string, string>
        const peakPercent = highest(snapshot.usage)
        const level = peakPercent >= 90 ? theme.error : peakPercent >= 70 ? theme.warning : theme.success

        const now = new Date()
        const deepseekPeak = isDeepseekPeak(now)
        const tariffColor = deepseekPeak ? theme.warning : theme.success
        const tariffLabel = deepseekPeak ? "peak" : "off-peak"
        const tariffChange = shortDuration(msUntilTariffChange(now))

        return (
          <box flexDirection="column">
            <Show when={snapshot.status !== "nokey" && snapshot.status !== "nogo"}>
              <box flexDirection="row" gap={1}>
                <text fg={level}>●</text>
                <text fg={theme.text}>Go usage</text>
                <Show when={snapshot.status === "relogin"}>
                  <text fg={theme.warning}>(relogin)</text>
                </Show>
                <Show when={snapshot.status === "error"}>
                  <text fg={theme.error}>(offline)</text>
                </Show>
              </box>
              <For each={WINDOWS}>
                {(win) => {
                  const value = snapshot.usage?.[win.key as keyof Usage]
                  const percent = Math.round(value?.percent ?? 0)
                  return (
                    <box flexDirection="row" gap={1}>
                      <text fg={theme.textMuted}>{win.label}</text>
                      <text fg={theme.text}>{bar(percent)}</text>
                      <text fg={level}>{String(percent).padStart(3, " ")}%</text>
                      <text fg={theme.textMuted}>{countdown(value?.resetsAt)}</text>
                    </box>
                  )
                }}
              </For>
            </Show>
            <Show when={snapshot.status === "nokey" || snapshot.status === "nogo"}>
              <box flexDirection="row" gap={1}>
                <text fg={theme.textMuted}>Go usage</text>
                <text fg={theme.textMuted}>{snapshot.status === "nogo" ? "(no subscription)" : "(not connected)"}</text>
              </box>
            </Show>
            <box flexDirection="row" gap={1}>
              <text fg={theme.textMuted}>DeepSeek</text>
              <text fg={tariffColor}>{tariffLabel}</text>
              <Show when={!deepseekPeak}>
                <text fg={theme.textMuted}>-50%</text>
              </Show>
              <text fg={theme.textMuted}>{tariffChange}</text>
            </box>
          </box>
        )
      },
    },
  })
}

const plugin = { id: "opencode-go-usage", tui }
export default plugin
TUI_EOF

echo "Installing plugin dependencies in $PLUGIN_DIR ..."
if command -v bun >/dev/null 2>&1; then
  (cd "$PLUGIN_DIR" && bun install)
elif command -v npm >/dev/null 2>&1; then
  (cd "$PLUGIN_DIR" && npm install --no-audit --no-fund)
else
  echo "Error: neither bun nor npm is available." >&2
  exit 1
fi

echo "Registering plugin in $TUI_CONFIG ..."
if command -v node >/dev/null 2>&1; then
  node - "$TUI_CONFIG" "$PLUGIN_PATH" <<'NODE_EOF'
const fs = require("node:fs")
const path = require("node:path")
const [configPath, pluginPath] = process.argv.slice(-2)
let config = {}
if (fs.existsSync(configPath) && fs.statSync(configPath).size > 0) {
  config = JSON.parse(fs.readFileSync(configPath, "utf8"))
}
if (!config || Array.isArray(config) || typeof config !== "object") {
  throw new Error(`${configPath} is not a JSON object`)
}
const plugins = Array.isArray(config.plugin) ? config.plugin : []
if (!plugins.includes(pluginPath)) plugins.push(pluginPath)
config.$schema = config.$schema || "https://opencode.ai/tui.json"
config.plugin = plugins
fs.mkdirSync(path.dirname(configPath), { recursive: true })
fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n")
NODE_EOF
elif command -v python3 >/dev/null 2>&1; then
  python3 - "$TUI_CONFIG" "$PLUGIN_PATH" <<'PY_EOF'
import json
import os
import sys

config_path, plugin_path = sys.argv[1], sys.argv[2]
config = {}
if os.path.exists(config_path) and os.path.getsize(config_path) > 0:
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
if not isinstance(config, dict):
    raise SystemExit(f"{config_path} is not a JSON object")
plugins = config.get("plugin")
if not isinstance(plugins, list):
    plugins = []
if plugin_path not in plugins:
    plugins.append(plugin_path)
config["$schema"] = config.get("$schema") or "https://opencode.ai/tui.json"
config["plugin"] = plugins
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
PY_EOF
else
  echo "Error: node or python3 is required to update tui.json." >&2
  exit 1
fi

echo
echo "Installed: $PLUGIN_PATH"
if [ -f "$DATA_DIR/opencode.db" ]; then
  echo "Console account database found: $DATA_DIR/opencode.db"
else
  echo "No opencode.db yet. Start opencode, run /connect, and sign in to OpenCode Console."
fi
echo "Restart opencode. The panel appears in the right sidebar of a session."
