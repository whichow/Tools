#!/usr/bin/env bash
set -euo pipefail

TARGET=""
SCOPE="repo"
PRESET="auto"
RUNNER_NAME=""
INSTALL_ROOT="$HOME/actions-runners"
EXTRA_LABELS=""
MODE="auto"
ALLOW_PUBLIC=0

usage() {
  cat <<'EOF'
Usage:
  install-runner.sh [options]

Options:
  --target OWNER/REPO        Repository target (repo scope) or ORG (org scope)
  --scope repo|org           Registration scope. Default: repo
  --preset auto|gpu|mac|scanner|android|robot|generic
  --name RUNNER_NAME         Override runner name
  --root PATH                Install root. Default: ~/actions-runners
  --labels a,b,c             Extra custom labels
  --mode auto|service|user   Default: auto
  --allow-public             Allow repository-level runner on a public repository
  -h, --help                 Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --preset) PRESET="$2"; shift 2 ;;
    --name) RUNNER_NAME="$2"; shift 2 ;;
    --root) INSTALL_ROOT="$2"; shift 2 ;;
    --labels) EXTRA_LABELS="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --allow-public) ALLOW_PUBLIC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$SCOPE" in repo|org) ;; *) echo "Invalid --scope: $SCOPE" >&2; exit 2;; esac
case "$PRESET" in auto|gpu|mac|scanner|android|robot|generic) ;; *) echo "Invalid --preset: $PRESET" >&2; exit 2;; esac
case "$MODE" in auto|service|user) ;; *) echo "Invalid --mode: $MODE" >&2; exit 2;; esac

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
normalize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'; }

if [[ -z "$TARGET" ]]; then
  default_target="whichow/PrivacyCamera"
  printf 'Repository (owner/repo) or organization [%s]: ' "$default_target" > /dev/tty
  IFS= read -r TARGET < /dev/tty || true
  TARGET="${TARGET:-$default_target}"
fi

get_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN"
    return
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    t="$(gh auth token 2>/dev/null || true)"
    if [[ -n "$t" ]]; then
      printf '%s' "$t"
      return
    fi
  fi
  printf 'GitHub token (repo Administration:write, input hidden): ' > /dev/tty
  stty -echo < /dev/tty
  IFS= read -r t < /dev/tty || true
  stty echo < /dev/tty
  printf '\n' > /dev/tty
  printf '%s' "$t"
}

TOKEN="$(get_token)"
[[ -n "$TOKEN" ]] || { echo "GitHub authentication token is required." >&2; exit 1; }

api_get() {
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    -H 'User-Agent: whichow-runner-bootstrap' \
    "$1"
}

api_post() {
  curl -fsSL -X POST \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    -H 'User-Agent: whichow-runner-bootstrap' \
    "$1"
}

if [[ "$SCOPE" == "repo" ]]; then
  [[ "$TARGET" == */* ]] || { echo "Repo scope target must be owner/repo." >&2; exit 2; }
  step "Checking repository $TARGET"
  repo_json="$(api_get "https://api.github.com/repos/$TARGET")"
  if [[ "$ALLOW_PUBLIC" -ne 1 ]] && ! grep -Eq '"private"[[:space:]]*:[[:space:]]*true' <<<"$repo_json"; then
    echo "Refusing to attach a self-hosted runner to public repository '$TARGET'. Use --allow-public only if you accept the security risk." >&2
    exit 1
  fi
  registration_url="https://api.github.com/repos/$TARGET/actions/runners/registration-token"
  scope_url="https://github.com/$TARGET"
else
  [[ "$TARGET" != */* ]] || { echo "Org scope target must be organization login only." >&2; exit 2; }
  registration_url="https://api.github.com/orgs/$TARGET/actions/runners/registration-token"
  scope_url="https://github.com/$TARGET"
fi

os_name="$(uname -s)"
machine="$(uname -m)"
case "$os_name" in
  Darwin) runner_os="osx"; default_preset="mac" ;;
  Linux) runner_os="linux"; default_preset="generic" ;;
  *) echo "Unsupported OS: $os_name" >&2; exit 1 ;;
esac

case "$machine" in
  arm64|aarch64) runner_arch="arm64" ;;
  x86_64|amd64) runner_arch="x64" ;;
  armv7l) runner_arch="arm" ;;
  *) echo "Unsupported architecture: $machine" >&2; exit 1 ;;
esac

if [[ "$PRESET" == "auto" ]]; then
  PRESET="$default_preset"
  if command -v nvidia-smi >/dev/null 2>&1; then PRESET="gpu"; fi
fi

host_name="$(normalize "$(hostname -s 2>/dev/null || hostname)")"
if [[ -z "$RUNNER_NAME" ]]; then RUNNER_NAME="$host_name-$PRESET"; fi
RUNNER_NAME="$(normalize "$RUNNER_NAME")"
RUNNER_NAME="${RUNNER_NAME:0:64}"

labels=("host-$host_name")
case "$PRESET" in
  gpu)
    labels+=(gpu unity ai-video)
    if command -v nvidia-smi >/dev/null 2>&1; then
      labels+=(nvidia)
      gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
      if grep -Eqi 'RTX[[:space:]]*5080' <<<"$gpu_name"; then labels+=(rtx5080); fi
    fi
    ;;
  mac) labels+=(apple-silicon xcode unity) ;;
  scanner) labels+=(scanner-x1 usb ble wifi unity) ;;
  android) labels+=(android-device adb camera) ;;
  robot) labels+=(robot esp32 camera) ;;
  generic) labels+=(ci) ;;
esac

if [[ -n "$EXTRA_LABELS" ]]; then
  IFS=',' read -ra more <<< "$EXTRA_LABELS"
  for l in "${more[@]}"; do
    l="$(normalize "$l")"
    [[ -n "$l" ]] && labels+=("$l")
  done
fi

# Unique labels while preserving order.
unique_labels=()
for candidate in "${labels[@]}"; do
  seen=0
  for existing in "${unique_labels[@]:-}"; do [[ "$existing" == "$candidate" ]] && seen=1 && break; done
  [[ "$seen" -eq 0 ]] && unique_labels+=("$candidate")
done
labels_csv="$(IFS=,; echo "${unique_labels[*]}")"

if [[ "$MODE" == "auto" ]]; then MODE="service"; fi

target_key="$(normalize "${TARGET//\//-}")"
install_dir="$INSTALL_ROOT/$target_key-$RUNNER_NAME"

step "Runner plan"
printf 'Target : %s %s\n' "$SCOPE" "$TARGET"
printf 'Name   : %s\n' "$RUNNER_NAME"
printf 'Labels : %s\n' "$labels_csv"
printf 'Mode   : %s\n' "$MODE"
printf 'Path   : %s\n' "$install_dir"

mkdir -p "$install_dir"
chmod 700 "$INSTALL_ROOT" "$install_dir" 2>/dev/null || true

if [[ -f "$install_dir/.runner" ]]; then
  echo "Runner is already configured in $install_dir; no destructive re-registration performed."
  if [[ "$MODE" == "service" && -x "$install_dir/svc.sh" ]]; then
    if [[ "$os_name" == "Linux" ]]; then sudo "$install_dir/svc.sh" start || true; else "$install_dir/svc.sh" start || true; fi
  fi
  exit 0
fi

step "Resolving latest GitHub Actions Runner"
latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest)"
version_tag="${latest_url##*/}"
version="${version_tag#v}"
archive="actions-runner-$runner_os-$runner_arch-$version.tar.gz"
download_url="https://github.com/actions/runner/releases/download/$version_tag/$archive"

step "Downloading $archive"
tmp_archive="$(mktemp -t actions-runner.XXXXXX.tar.gz)"
curl -fL --retry 3 --retry-delay 2 "$download_url" -o "$tmp_archive"
tar xzf "$tmp_archive" -C "$install_dir"
rm -f "$tmp_archive"

step "Creating one-hour registration token"
registration_json="$(api_post "$registration_url")"
registration_token="$(printf '%s' "$registration_json" | sed -nE 's/.*"token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
[[ -n "$registration_token" ]] || { echo "GitHub did not return a registration token." >&2; exit 1; }

cd "$install_dir"
step "Registering runner"
./config.sh --unattended --replace \
  --url "$scope_url" \
  --token "$registration_token" \
  --name "$RUNNER_NAME" \
  --work _work \
  --labels "$labels_csv"
unset registration_token TOKEN

if [[ "$MODE" == "service" ]]; then
  step "Installing runner service"
  if [[ "$os_name" == "Linux" ]]; then
    sudo ./svc.sh install "$USER"
    sudo ./svc.sh start
    sudo ./svc.sh status || true
  else
    ./svc.sh install
    ./svc.sh start
    ./svc.sh status || true
  fi
else
  step "Starting runner in current user session"
  nohup ./run.sh > runner-user.log 2>&1 &
  echo $! > runner-user.pid
  if [[ "$os_name" == "Darwin" ]]; then
    echo "Tip: use --mode service on macOS for launchd auto-start." >&2
  else
    echo "Tip: use --mode service on Linux for systemd auto-start." >&2
  fi
fi

step "Done"
printf "Runner '%s' is registered for %s\n" "$RUNNER_NAME" "$scope_url"
printf 'Custom labels: %s\n' "$labels_csv"
