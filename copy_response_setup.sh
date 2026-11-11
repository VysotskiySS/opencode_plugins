#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$CONFIG_DIR/plugins/copy-response"
TUI_JSON="$CONFIG_DIR/tui.json"
INSTALL_DEPS=1

for arg in "$@"; do
  case "$arg" in
    --no-deps) INSTALL_DEPS=0 ;;
    -h|--help)
      echo "Usage: $0 [--no-deps]"
      echo "  --no-deps  skip npm install (use when node_modules is copied manually)"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 1
}
if [ "$INSTALL_DEPS" -eq 1 ]; then
  command -v npm >/dev/null 2>&1 || {
    echo "npm is required (or pass --no-deps and copy node_modules manually)" >&2
    exit 1
  }
fi

mkdir -p "$PLUGIN_DIR"

cat >"$PLUGIN_DIR/package.json" <<'JSON'
{
  "name": "opencode-copy-response",
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
JSON

cat >"$PLUGIN_DIR/tui.tsx" <<'TSX'
/** @jsxImportSource @opentui/solid */
import { createSignal } from "solid-js"

type MessageLike = { id: string; role?: string }
type PartLike = { type: string; text?: string }

function lastAssistantText(api: any, sessionID: string): string | undefined {
  const messages = api.state.session.messages(sessionID) as readonly MessageLike[]
  let message: MessageLike | undefined
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]?.role === "assistant") {
      message = messages[i]
      break
    }
  }
  if (!message) return undefined

  const parts = api.state.part(message.id) as readonly PartLike[]
  const text = parts
    .filter((part) => part.type === "text" && typeof part.text === "string")
    .map((part) => part.text as string)
    .join("\n")
    .trim()
  return text || undefined
}

function nativeCopy(text: string): boolean {
  const stdin = new TextEncoder().encode(text)
  const commands = [
    ["wl-copy"],
    ["xclip", "-selection", "clipboard"],
    ["xsel", "--clipboard", "--input"],
    ["pbcopy"],
  ]
  const bun = (globalThis as any).Bun
  if (!bun?.spawnSync) return false
  for (const cmd of commands) {
    try {
      const result = bun.spawnSync({ cmd, stdin, stdout: "ignore", stderr: "ignore" })
      if (result?.exitCode === 0) return true
    } catch {}
  }
  return false
}

const tui = async (api: any) => {
  const [copied, setCopied] = createSignal(false)
  let timer: ReturnType<typeof setTimeout> | undefined

  const copy = (sessionID: string) => {
    const text = lastAssistantText(api, sessionID)
    if (!text) {
      api.ui.toast({ variant: "error", message: "No assistant response to copy" })
      return
    }
    const ok = nativeCopy(text) || api.renderer.copyToClipboardOSC52(text)
    api.ui.toast({
      variant: ok ? "success" : "error",
      message: ok ? "Response copied to clipboard" : "Failed to copy response",
    })
    if (!ok) return
    setCopied(true)
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => setCopied(false), 1500)
  }

  api.slots.register({
    order: 100,
    slots: {
      session_prompt_right(
        ctx: { theme: { current: Record<string, string> } },
        props: { session_id: string },
      ) {
        return (
          <box
            flexDirection="row"
            gap={1}
            onMouseUp={(event: any) => {
              if (api.renderer.getSelection()?.getSelectedText()) return
              event?.preventDefault?.()
              event?.stopPropagation?.()
              copy(props.session_id)
            }}
          >
            <text fg={copied() ? ctx.theme.current.success : ctx.theme.current.textMuted}>
              {copied() ? "✓ Copied" : "⧉ Copy"}
            </text>
          </box>
        )
      },
    },
  })
}

const plugin = { id: "copy-response", tui }
export default plugin
TSX

if [ "$INSTALL_DEPS" -eq 1 ] && [ ! -d "$PLUGIN_DIR/node_modules/@opentui/solid" ]; then
  echo "Installing plugin dependencies..."
  (cd "$PLUGIN_DIR" && npm install --no-audit --no-fund)
fi

if [ -f "$TUI_JSON" ]; then
  cp "$TUI_JSON" "$TUI_JSON.bak-copy-response"
fi

python3 - "$TUI_JSON" "$PLUGIN_DIR/tui.tsx" <<'PY'
import json
import os
import sys

path, plugin = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(path), exist_ok=True)

data = {}
if os.path.exists(path):
    with open(path, "r", encoding="utf-8") as handle:
        try:
            data = json.load(handle)
        except json.JSONDecodeError:
            raise SystemExit(f"Cannot parse {path}: fix or remove it first")

if not isinstance(data, dict):
    raise SystemExit(f"{path} must contain a JSON object")

data.setdefault("$schema", "https://opencode.ai/tui.json")

plugins = data.get("plugin") or []
if isinstance(plugins, str):
    plugins = [plugins]
elif not isinstance(plugins, list):
    plugins = []
if plugin not in plugins:
    plugins.append(plugin)
data["plugin"] = plugins

keybinds = data.get("keybinds")
if not isinstance(keybinds, dict):
    keybinds = {}
if "messages_copy" not in keybinds:
    keybinds["messages_copy"] = ["<leader>y", "ctrl+alt+c"]
data["keybinds"] = keybinds

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
os.replace(tmp, path)
PY

add_env() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  if grep -q "OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT" "$rc"; then
    return 0
  fi
  {
    echo ""
    echo "# opencode: do not auto-copy mouse selection (sidebar included)"
    echo "export OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=1"
  } >>"$rc"
  echo "Updated $rc"
}

add_env "$HOME/.bashrc"
add_env "$HOME/.zshrc"
if [ ! -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ]; then
  touch "$HOME/.profile"
  add_env "$HOME/.profile"
fi

cat <<EOF
Done.

Plugin:  $PLUGIN_DIR/tui.tsx
Config:  $TUI_JSON
Env:     OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT=1

Restart opencode (and open a new shell or run: source ~/.bashrc).

Usage:
  - click "⧉ Copy" next to the prompt
  - Ctrl+X then Y, or Ctrl+Alt+C
  - mouse drag no longer overwrites the clipboard; Ctrl+C copies the selection
EOF
