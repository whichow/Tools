#!/usr/bin/env bash
set -euo pipefail

TARGET=""
SCOPE="repo"
INSTALL_DIR=""
KEEP_FILES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --dir) INSTALL_DIR="$2"; shift 2 ;;
    --keep-files) KEEP_FILES=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$TARGET" && -n "$INSTALL_DIR" ]] || { echo "Usage: uninstall-runner.sh --target OWNER/REPO --dir PATH [--scope repo|org] [--keep-files]" >&2; exit 2; }
[[ -f "$INSTALL_DIR/.runner" ]] || { echo "No configured runner found at $INSTALL_DIR" >&2; exit 1; }

get_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then printf '%s' "$GH_TOKEN"; return; fi
  if command -v gh >/dev/null 2>&1; then
    local t; t="$(gh auth token 2>/dev/null || true)"; [[ -n "$t" ]] && { printf '%s' "$t"; return; }
  fi
  printf 'GitHub token: ' > /dev/tty; stty -echo < /dev/tty; IFS= read -r t < /dev/tty || true; stty echo < /dev/tty; printf '\n' > /dev/tty; printf '%s' "$t"
}
TOKEN="$(get_token)"

if [[ "$SCOPE" == "repo" ]]; then
  remove_url="https://api.github.com/repos/$TARGET/actions/runners/remove-token"
else
  remove_url="https://api.github.com/orgs/$TARGET/actions/runners/remove-token"
fi
json="$(curl -fsSL -X POST -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $TOKEN" -H 'X-GitHub-Api-Version: 2026-03-10' -H 'User-Agent: whichow-runner-bootstrap' "$remove_url")"
remove_token="$(printf '%s' "$json" | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
[[ -n "$remove_token" ]] || { echo "Failed to obtain remove token" >&2; exit 1; }

cd "$INSTALL_DIR"
if [[ -x ./svc.sh ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then
    sudo ./svc.sh stop || true
    sudo ./svc.sh uninstall || true
  else
    ./svc.sh stop || true
    ./svc.sh uninstall || true
  fi
fi

if [[ -f runner-user.pid ]]; then
  kill "$(cat runner-user.pid)" 2>/dev/null || true
fi
./config.sh remove --unattended --token "$remove_token"
unset TOKEN remove_token

cd /
if [[ "$KEEP_FILES" -ne 1 ]]; then rm -rf "$INSTALL_DIR"; fi
echo "Runner removed from $TARGET"
