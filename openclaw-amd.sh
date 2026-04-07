#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="openclaw-amd"
SCRIPT_VERSION="0.5.0"

OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_PATH:-$HOME/.openclaw/openclaw.json}"
LMSTUDIO_BASE_URL="${LMSTUDIO_BASE_URL:-}"
OPENCLAW_AMD_MODEL_ID="${OPENCLAW_AMD_MODEL_ID:-}"
OPENCLAW_AMD_CONTEXT_TOKENS="${OPENCLAW_AMD_CONTEXT_TOKENS:-190000}"
OPENCLAW_AMD_MODEL_MAX_TOKENS="${OPENCLAW_AMD_MODEL_MAX_TOKENS:-64000}"
OPENCLAW_AMD_MAX_AGENTS="${OPENCLAW_AMD_MAX_AGENTS:-2}"
OPENCLAW_AMD_MAX_SUBAGENTS="${OPENCLAW_AMD_MAX_SUBAGENTS:-2}"
OPENCLAW_AMD_GATEWAY_PORT="${OPENCLAW_AMD_GATEWAY_PORT:-18789}"
OPENCLAW_AMD_GATEWAY_BIND="${OPENCLAW_AMD_GATEWAY_BIND:-loopback}"
OPENCLAW_AMD_SKIP_TUNING="${OPENCLAW_AMD_SKIP_TUNING:-0}"

SYSTEMD_READY=0
RAN_ONBOARD=0

print_banner() {
  printf '\033[1;31m░████░░█░░░█░█████░░████░█░░░█░░░░░████░░▀█▀░░████░░████░░▀█▀\033[0m\n'
  printf '\033[1;31m█░░░█░░█░░░█░░░█░░░█░░░░░█░██░░░░░█░░░░░░█░░░█░░░█░█░░░█░░█░\033[0m\n'
  printf '\033[1;31m█░░░█░░█░░░█░░░█░░░█░░░░░██░░░░░░░░███░░░█░░░█████░████░░░█░\033[0m\n'
  printf '\033[1;31m█░█░█░░█░░░█░░░█░░░█░░░░░█░██░░░░░░░░░█░░█░░░█░░░█░█░░█░░░█░\033[0m\n'
  printf '\033[1;31m░█░█░░░░███░░░█░░░░████░█░░░█░░░░░████░░░█░░░█░░░█░█░░░█░░█░\033[0m\n'
  printf '\033[1;33m    🦞  OpenClaw on AMD (LM Studio + WSL2)  🦞\033[0m\n'
  printf '\n'
}

info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    have sudo || die "sudo is required to continue"
    sudo "$@"
  fi
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null || \
    grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "This script is for Linux/WSL only. Run it inside Ubuntu/WSL on Windows."
}

append_line_if_missing() {
  local file="$1"
  local line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -qxF "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

prepare_npm_global_prefix() {
  mkdir -p "$HOME/.config/systemd/user" "$HOME/.npm-global" "$HOME/.local/bin"

  # Persist both ~/.npm-global/bin and ~/.local/bin (where openclaw may install)
  local path_line='export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'
  append_line_if_missing "$HOME/.profile" "$path_line"
  append_line_if_missing "$HOME/.bashrc" "$path_line"
  if [[ -f "$HOME/.zshrc" ]]; then
    append_line_if_missing "$HOME/.zshrc" "$path_line"
  fi

  export NPM_CONFIG_PREFIX="$HOME/.npm-global"
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
    # Also add the npm global prefix bin to profiles
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" && "$npm_prefix" != "$HOME/.npm-global" ]]; then
      local npm_path_line="export PATH=\"${npm_prefix}/bin:\$PATH\""
      append_line_if_missing "$HOME/.profile" "$npm_path_line"
      append_line_if_missing "$HOME/.bashrc" "$npm_path_line"
      export PATH="${npm_prefix}/bin:$PATH"
    fi
  fi
  hash -r 2>/dev/null || true
}

apt_install_if_missing() {
  have apt-get || die "This script currently targets Ubuntu/Debian/WSL environments with apt-get."
  local missing=()
  local pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    info "Installing required packages: ${missing[*]}"
    run_root apt-get update
    DEBIAN_FRONTEND=noninteractive run_root apt-get install -y "${missing[@]}"
  fi
}

maybe_enable_wsl_systemd() {
  if ! is_wsl; then
    local init_comm
    init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$init_comm" == "systemd" ]] && SYSTEMD_READY=1
    return 0
  fi

  info "Detected WSL"
  local init_comm
  init_comm="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$init_comm" == "systemd" ]]; then
    SYSTEMD_READY=1
    return 0
  fi

  info "Ensuring systemd is enabled in /etc/wsl.conf"
  if run_root test -f /etc/wsl.conf; then
    local backup_path="/etc/wsl.conf.bak.${SCRIPT_NAME}.$(date +%s)"
    run_root cp /etc/wsl.conf "$backup_path"
    info "Backed up /etc/wsl.conf to $backup_path"
  fi

  run_root python3 - <<'PY'
from pathlib import Path
import configparser
path = Path('/etc/wsl.conf')
cp = configparser.ConfigParser(strict=False)
if path.exists():
    cp.read(path)
if not cp.has_section('boot'):
    cp.add_section('boot')
cp.set('boot', 'systemd', 'true')
with path.open('w', encoding='utf-8') as f:
    cp.write(f)
PY

  warn "systemd was not active in this WSL session."
  warn "Run 'wsl --shutdown' from PowerShell, reopen Ubuntu/WSL, and rerun the same curl | bash command."
  exit 10
}

# ---------------------------------------------------------------------------
# LM Studio detection — resolve Windows host IP from inside WSL2
# ---------------------------------------------------------------------------

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"

# Probe a candidate IP for a reachable LM Studio API.
# Tries the native /api/v1 endpoint first, then the OpenAI-compat /v1 endpoint.
probe_lmstudio() {
  local ip="$1"
  curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/v1/models" >/dev/null 2>&1 \
    || curl -fsS --max-time 2 "http://${ip}:${LMSTUDIO_PORT}/api/v1/models" >/dev/null 2>&1
}

resolve_lmstudio_url() {
  # Already set via environment (e.g. forwarded from PowerShell)
  if [[ -n "$LMSTUDIO_BASE_URL" ]]; then
    info "LM Studio base URL from environment: $LMSTUDIO_BASE_URL"
    return 0
  fi

  info "Detecting LM Studio on Windows host..."

  # Collect unique candidate IPs to try, in priority order
  local -a candidates=()

  # 1. Mirrored networking (newer Windows 11) — localhost works directly
  candidates+=("127.0.0.1")

  # 2. Default gateway — usually the Windows host in WSL2 NAT mode
  local gw_ip
  gw_ip="$(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || true)"
  if [[ -n "$gw_ip" ]] && [[ "$gw_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    candidates+=("$gw_ip")
  fi

  # 3. /etc/resolv.conf nameserver
  local dns_ip
  if [[ -f /etc/resolv.conf ]]; then
    dns_ip="$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}' || true)"
    if [[ -n "$dns_ip" ]] && [[ "$dns_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$dns_ip")
    fi
  fi

  # 4. Ask PowerShell for ALL host IPv4 addresses (WSL adapter, LAN, Wi-Fi, etc.)
  #    This catches the real LAN IP (e.g. 192.168.0.218) that LM Studio binds to
  #    when "Serve on Local Network" is enabled.
  local ps_ips
  ps_ips="$(powershell.exe -NoProfile -Command \
    'Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } | ForEach-Object { $_.IPAddress }' \
    2>/dev/null | tr -d '\r' || true)"
  local ps_ip
  while IFS= read -r ps_ip; do
    ps_ip="${ps_ip// /}"
    if [[ -n "$ps_ip" ]] && [[ "$ps_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      candidates+=("$ps_ip")
    fi
  done <<< "$ps_ips"

  # De-duplicate while preserving order
  local -a unique=()
  local -A seen=()
  local c
  for c in "${candidates[@]}"; do
    if [[ -z "${seen[$c]+x}" ]]; then
      seen[$c]=1
      unique+=("$c")
    fi
  done

  # Probe each candidate
  for c in "${unique[@]}"; do
    info "  Trying ${c}:${LMSTUDIO_PORT} ..."
    if probe_lmstudio "$c"; then
      LMSTUDIO_BASE_URL="http://${c}:${LMSTUDIO_PORT}"
      info "LM Studio found at: $LMSTUDIO_BASE_URL"
      return 0
    fi
  done

  # None worked — ask the user
  warn "Could not auto-detect LM Studio. Tried: ${unique[*]}"
  warn "Ensure LM Studio is running on Windows with a model loaded."
  warn "Ensure 'Serve on Local Network' is enabled in LM Studio settings."
  warn "Ensure Windows Firewall allows inbound connections on port ${LMSTUDIO_PORT}."
  printf '\n'
  read -r -p "Enter the LM Studio host IP (e.g. 192.168.0.218): " user_ip < /dev/tty
  user_ip="${user_ip// /}"
  if [[ -z "$user_ip" ]]; then
    die "No IP provided. Set LMSTUDIO_BASE_URL manually (e.g. LMSTUDIO_BASE_URL=http://192.168.0.218:${LMSTUDIO_PORT})."
  fi
  LMSTUDIO_BASE_URL="http://${user_ip}:${LMSTUDIO_PORT}"
  info "Using user-provided LM Studio URL: $LMSTUDIO_BASE_URL"
}

wait_for_lmstudio() {
  local url="${LMSTUDIO_BASE_URL}/v1/models"
  local attempts=0
  local max_attempts=10

  info "Checking LM Studio API at ${url}"
  while (( attempts < max_attempts )); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      info "LM Studio API is reachable"
      return 0
    fi
    (( attempts++ )) || true
    if (( attempts == 1 )); then
      warn "LM Studio not reachable yet."
      warn "Ensure LM Studio is running on Windows with a model loaded."
      warn "Ensure Windows Firewall allows inbound connections on port 1234."
    fi
    sleep 2
  done

  die "LM Studio API at ${url} is not reachable after ${max_attempts} attempts. Start LM Studio, load a model, check firewall, and rerun."
}

# ---------------------------------------------------------------------------
# Dynamic model selection from LM Studio
# ---------------------------------------------------------------------------

# Interactive arrow-key menu.  Reads from /dev/tty so it works even when
# the script itself is piped in via  curl … | bash.
#
# Usage:  pick_from_menu RESULT_VAR "Prompt text" item1 item2 …
pick_from_menu() {
  local _result_var="$1"; shift
  local _prompt="$1"; shift
  local -a _items=("$@")
  local _count=${#_items[@]}
  local _cur=0

  # Save terminal state and switch to raw mode on /dev/tty
  local _old_stty
  _old_stty="$(stty -g < /dev/tty 2>/dev/null)"
  stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null

  # Hide cursor
  printf '\033[?25l' > /dev/tty

  _draw_menu() {
    # Move cursor to start of menu area and redraw
    local i
    for i in "${!_items[@]}"; do
      printf '\r\033[2K' > /dev/tty
      if (( i == _cur )); then
        printf '  \033[1;7;36m > %s \033[0m\n' "${_items[$i]}" > /dev/tty
      else
        printf '  \033[0;90m   %s\033[0m\n' "${_items[$i]}" > /dev/tty
      fi
    done
    printf '\r\033[2K\033[0;33m  ↑↓ move  ⏎ select\033[0m' > /dev/tty
    # Move cursor back up to top of menu + hint line
    printf '\033[%dA' "$(( _count ))" > /dev/tty
  }

  printf '\n' > /dev/tty
  printf '\033[1;34m[INFO]\033[0m %s\n\n' "$_prompt" > /dev/tty
  _draw_menu

  local _key
  while true; do
    # Read one byte from /dev/tty
    IFS= read -r -n1 _key < /dev/tty 2>/dev/null || true

    if [[ "$_key" == $'\x1b' ]]; then
      # Escape sequence — read two more bytes for arrow keys
      local _seq1 _seq2
      IFS= read -r -n1 -t 0.1 _seq1 < /dev/tty 2>/dev/null || true
      IFS= read -r -n1 -t 0.1 _seq2 < /dev/tty 2>/dev/null || true
      if [[ "$_seq1" == "[" ]]; then
        case "$_seq2" in
          A) # Up arrow
            (( _cur > 0 )) && (( _cur-- ))
            _draw_menu
            ;;
          B) # Down arrow
            (( _cur < _count - 1 )) && (( _cur++ )) || true
            _draw_menu
            ;;
        esac
      fi
    elif [[ "$_key" == "" || "$_key" == $'\n' ]]; then
      # Enter pressed — accept selection
      break
    elif [[ "$_key" == "k" ]]; then
      (( _cur > 0 )) && (( _cur-- ))
      _draw_menu
    elif [[ "$_key" == "j" ]]; then
      (( _cur < _count - 1 )) && (( _cur++ )) || true
      _draw_menu
    fi
  done

  # Move past the menu and hint line, show cursor, restore terminal
  printf '\033[%dB' "$(( _count ))" > /dev/tty
  printf '\r\033[2K\n' > /dev/tty
  printf '\033[?25h' > /dev/tty
  stty "$_old_stty" < /dev/tty 2>/dev/null || true

  eval "$_result_var=\${_items[\$_cur]}"
}

select_lmstudio_model() {
  # If model already set by env var, skip selection
  if [[ -n "$OPENCLAW_AMD_MODEL_ID" ]]; then
    info "Using model from environment: $OPENCLAW_AMD_MODEL_ID"
    return 0
  fi

  local models_url="${LMSTUDIO_BASE_URL}/v1/models"
  local response
  response="$(curl -fsS --max-time 5 "$models_url")" \
    || die "Failed to query models from LM Studio at ${models_url}"

  # Parse model IDs, filter out embedding models
  local model_list
  model_list="$(printf '%s' "$response" | python3 -c "
import json, sys
data = json.load(sys.stdin)
models = data.get('data', [])
if not models:
    sys.exit(1)
for m in models:
    mid = m.get('id', '')
    if 'embed' in mid.lower():
        continue
    print(mid)
" 2>/dev/null)" || die "No models loaded in LM Studio. Load a model in LM Studio and rerun."

  # Read into array
  local -a models=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && models+=("$line")
  done <<< "$model_list"

  if (( ${#models[@]} == 0 )); then
    die "No models found in LM Studio. Load a model and rerun."
  fi

  if (( ${#models[@]} == 1 )); then
    OPENCLAW_AMD_MODEL_ID="${models[0]}"
    info "Only one model loaded: ${OPENCLAW_AMD_MODEL_ID}"
    return 0
  fi

  # Multiple models — interactive arrow-key picker
  pick_from_menu OPENCLAW_AMD_MODEL_ID "Select a model from LM Studio:" "${models[@]}"
  info "Selected model: ${OPENCLAW_AMD_MODEL_ID}"
}

# ---------------------------------------------------------------------------
# Google Chrome — required so OpenClaw can drive a visible browser inside WSL2
# ---------------------------------------------------------------------------
install_chrome_if_missing() {
  if have google-chrome-stable || have google-chrome || have chromium-browser || have chromium; then
    info "Chrome/Chromium already installed — skipping"
    return 0
  fi

  info "Installing Google Chrome"
  apt_install_if_missing wget gnupg2

  wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
    | run_root gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg

  printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' \
    | run_root tee /etc/apt/sources.list.d/google-chrome.list >/dev/null

  run_root apt-get update
  DEBIAN_FRONTEND=noninteractive run_root apt-get install -y google-chrome-stable

  have google-chrome-stable || warn "Chrome install finished but 'google-chrome-stable' not found on PATH."

  info "Google Chrome installed"
}

# ---------------------------------------------------------------------------
# Homebrew (Linuxbrew) — needed by some OpenClaw skills
# ---------------------------------------------------------------------------
install_homebrew_if_missing() {
  if have brew; then
    info "Homebrew already installed — skipping"
    return 0
  fi

  info "Installing Homebrew (Linuxbrew)..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH and persist to shell profiles
  local brew_path=""
  if [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]]; then
    brew_path="/home/linuxbrew/.linuxbrew/bin/brew"
  elif [[ -x "$HOME/.linuxbrew/bin/brew" ]]; then
    brew_path="$HOME/.linuxbrew/bin/brew"
  fi

  if [[ -n "$brew_path" ]]; then
    eval "$("$brew_path" shellenv)"
    local brew_env_line="eval \"\$($brew_path shellenv)\""
    append_line_if_missing "$HOME/.profile" "$brew_env_line"
    append_line_if_missing "$HOME/.bashrc" "$brew_env_line"
    if [[ -f "$HOME/.zshrc" ]]; then
      append_line_if_missing "$HOME/.zshrc" "$brew_env_line"
    fi
    info "Homebrew installed and added to PATH"
  else
    warn "Homebrew install finished but brew binary not found at expected locations."
  fi
}

# ---------------------------------------------------------------------------
# OpenClaw install
# ---------------------------------------------------------------------------
install_or_update_openclaw() {
  prepare_npm_global_prefix
  refresh_openclaw_path
  if have openclaw; then
    info "OpenClaw already installed — skipping installer"
  else
    info "Installing OpenClaw"
    curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard
    if have npm; then
      npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true
    fi
  fi
  persist_openclaw_path
}

refresh_openclaw_path() {
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  if have npm; then
    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null || true)"
    if [[ -n "$npm_prefix" ]]; then
      export PATH="$npm_prefix/bin:$npm_prefix:$PATH"
    fi
  fi
  # Also check common Node.js version-manager paths (nvm, fnm, volta)
  for candidate_dir in \
    "$HOME/.nvm/versions/node"/*/bin \
    "$HOME/.local/share/fnm/node-versions"/*/installation/bin \
    "$HOME/.volta/bin"; do
    if [[ -d "$candidate_dir" ]]; then
      export PATH="$candidate_dir:$PATH"
    fi
  done
  hash -r 2>/dev/null || true
}

persist_openclaw_path() {
  refresh_openclaw_path
  local openclaw_bin
  openclaw_bin="$(command -v openclaw 2>/dev/null || true)"
  if [[ -z "$openclaw_bin" ]]; then
    # Search common install locations
    for search_dir in \
      "$HOME/.local/bin" \
      "$HOME/.npm-global/bin" \
      "$HOME/.nvm/versions/node"/*/bin \
      "$HOME/.local/share/fnm/node-versions"/*/installation/bin \
      "$HOME/.volta/bin" \
      /usr/local/bin; do
      if [[ -x "$search_dir/openclaw" ]]; then
        openclaw_bin="$search_dir/openclaw"
        break
      fi
    done
  fi
  if [[ -n "$openclaw_bin" ]]; then
    local bin_dir
    bin_dir="$(dirname "$openclaw_bin")"
    info "Found openclaw at $openclaw_bin"
    local path_line="export PATH=\"${bin_dir}:\$PATH\""
    append_line_if_missing "$HOME/.profile" "$path_line"
    append_line_if_missing "$HOME/.bashrc" "$path_line"
    if [[ -f "$HOME/.zshrc" ]]; then
      append_line_if_missing "$HOME/.zshrc" "$path_line"
    fi
    export PATH="$bin_dir:$PATH"
    hash -r 2>/dev/null || true
  fi
}

require_openclaw() {
  refresh_openclaw_path
  have openclaw || die "OpenClaw installed, but the 'openclaw' command is not on PATH yet. Open a new shell and rerun the script."
}

backup_openclaw_config() {
  local cfg="$1"
  if [[ -f "$cfg" ]]; then
    local backup="${cfg}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$cfg" "$backup"
    info "Backed up existing config to $backup"
  fi
}

# ---------------------------------------------------------------------------
# Configure OpenClaw against LM Studio non-interactively.
# ---------------------------------------------------------------------------
run_noninteractive_onboard() {
  local base_url="$1"
  local provider_id="lmstudio"
  local api_key="lm-studio"

  local cmd=(
    openclaw onboard
    --non-interactive
    --mode local
    --auth-choice custom-api-key
    --custom-base-url "$base_url"
    --custom-model-id "$OPENCLAW_AMD_MODEL_ID"
    --custom-provider-id "$provider_id"
    --custom-compatibility "anthropic"
    --custom-api-key "$api_key"
    --secret-input-mode plaintext
    --gateway-port "$OPENCLAW_AMD_GATEWAY_PORT"
    --gateway-bind "$OPENCLAW_AMD_GATEWAY_BIND"
    --skip-health
    --accept-risk
  )

  info "Configuring OpenClaw against LM Studio (${base_url})"
  if "${cmd[@]}"; then
    RAN_ONBOARD=1
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Check if OpenClaw is already configured for LM Studio provider/model.
# ---------------------------------------------------------------------------
is_openclaw_configured() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 1
  python3 - <<'PY' "$OPENCLAW_CONFIG_FILE" "lmstudio" "$OPENCLAW_AMD_MODEL_ID"
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
except Exception:
    sys.exit(1)
provider_id = sys.argv[2]
model_id    = sys.argv[3]

providers = cfg.get('models', {}).get('providers', {})
if provider_id not in providers:
    sys.exit(1)
provider = providers[provider_id]

models = provider.get('models', [])
if not any(isinstance(m, dict) and m.get('id') == model_id for m in models):
    sys.exit(1)

if not cfg.get('gateway'):
    sys.exit(1)
sys.exit(0)
PY
}

auto_tune_config() {
  [[ "$OPENCLAW_AMD_SKIP_TUNING" == "1" ]] && return 0
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || return 0

  local context_tokens="$OPENCLAW_AMD_CONTEXT_TOKENS"

  python3 - <<'PY' \
    "$OPENCLAW_CONFIG_FILE" \
    "lmstudio" \
    "$OPENCLAW_AMD_MODEL_ID" \
    "$context_tokens" \
    "$OPENCLAW_AMD_MODEL_MAX_TOKENS" \
    "$OPENCLAW_AMD_MAX_AGENTS" \
    "$OPENCLAW_AMD_MAX_SUBAGENTS" \
    "$LMSTUDIO_BASE_URL"
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
provider_id = sys.argv[2]
model_id = sys.argv[3]
context_tokens = int(sys.argv[4])
model_max_tokens = int(sys.argv[5])
max_agents = int(sys.argv[6])
max_subagents = int(sys.argv[7])
lmstudio_base_url = sys.argv[8]

cfg = json.loads(config_path.read_text(encoding='utf-8'))
agents = cfg.setdefault('agents', {})
defaults = agents.setdefault('defaults', {})

model_ref = f"{provider_id}/{model_id}"

current_model = defaults.get('model')
if isinstance(current_model, str):
    defaults['model'] = {'primary': model_ref}
elif isinstance(current_model, dict):
    current_model['primary'] = model_ref
else:
    defaults['model'] = {'primary': model_ref}

default_models = defaults.setdefault('models', {})
default_models.setdefault(model_ref, {})
default_models[model_ref].setdefault('alias', 'lmstudio-local')

defaults['contextTokens'] = context_tokens
defaults['maxConcurrent'] = max_agents
subagents = defaults.setdefault('subagents', {})
subagents['maxConcurrent'] = max_subagents

models_root = cfg.setdefault('models', {})
providers = models_root.setdefault('providers', {})
provider = providers.setdefault(provider_id, {})
provider_models = provider.setdefault('models', [])

entry = None
for item in provider_models:
    if isinstance(item, dict) and item.get('id') == model_id:
        entry = item
        break
if entry is None:
    entry = {'id': model_id, 'name': model_id}
    provider_models.append(entry)

entry['contextWindow'] = context_tokens
entry['maxTokens'] = model_max_tokens

# --- Embeddings via LM Studio's nomic-embed (OpenAI-compatible /v1/embeddings) ---
ms = defaults.setdefault('memorySearch', {})
ms['enabled'] = True
ms['provider'] = 'openai'
ms['model'] = 'text-embedding-nomic-embed-text-v1.5'
remote = ms.setdefault('remote', {})
remote['baseUrl'] = lmstudio_base_url + '/v1'
remote['apiKey'] = 'lm-studio'

# --- Browser profile: connect to Chrome via CDP on port 9222 ---
browser = cfg.setdefault('browser', {})
profiles = browser.setdefault('profiles', {})
chrome_profile = profiles.setdefault('default', {})
chrome_profile['cdpUrl'] = 'http://127.0.0.1:9222'
chrome_profile.setdefault('color', '4A90D9')

config_path.write_text(json.dumps(cfg, indent=2, sort_keys=False) + "\n", encoding='utf-8')
PY

  info "Applied OpenClaw tuning to ${OPENCLAW_CONFIG_FILE}"
  info "Embeddings configured (nomic-embed-text via LM Studio at ${LMSTUDIO_BASE_URL})"
}

# ---------------------------------------------------------------------------
# Append browser/environment info to TOOLS.md so the agent knows its setup.
# ---------------------------------------------------------------------------
write_tools_md() {
  local ws_dir="$HOME/.openclaw/workspace"
  local tools_file="$ws_dir/TOOLS.md"

  # Only append if the file exists (created by interactive onboard) and
  # our marker isn't already present (idempotent on re-runs).
  if [[ -f "$tools_file" ]] && ! grep -q '## Chrome Browser Usage and Control' "$tools_file" 2>/dev/null; then
    info "Appending browser environment info to TOOLS.md"
    cat >> "$tools_file" <<'TOOLS_APPEND'

## Chrome Browser Usage and Control
- Chrome is running inside WSL2 with CDP on port 9222
- DISPLAY=:0 is set for WSLg
- If the user asks you to open a browser or visit a URL, use Chrome via the commands below
- Use the `default` browser profile: `openclaw browser --browser-profile default`
- Do NOT use xdg-open or wslview (those open Windows host browsers)
- To navigate: `openclaw browser --browser-profile default navigate <url>`
- To launch Chrome manually: `DISPLAY=:0 google-chrome-stable --remote-debugging-port=9222 --user-data-dir=$HOME/.openclaw/browser/chrome-profile`

## Environment
- Platform: WSL2 (Ubuntu) on Windows
- LLM Backend: LM Studio (local, Anthropic-compatible API)
- Embeddings: nomic-embed-text via LM Studio (OpenAI-compatible /v1/embeddings)
TOOLS_APPEND
  elif [[ ! -f "$tools_file" ]]; then
    # Workspace wasn't created by onboard — write the file ourselves
    mkdir -p "$ws_dir"
    info "Creating TOOLS.md with browser environment info"
    cat > "$tools_file" <<'TOOLS_NEW'
# Tools

## Chrome Browser Usage and Control
- Chrome is running inside WSL2 with CDP on port 9222
- DISPLAY=:0 is set for WSLg
- If the user asks you to open a browser or visit a URL, use Chrome via the commands below
- Use the `default` browser profile: `openclaw browser --browser-profile default`
- Do NOT use xdg-open or wslview (those open Windows host browsers)
- To navigate: `openclaw browser --browser-profile default navigate <url>`
- To launch Chrome manually: `DISPLAY=:0 google-chrome-stable --remote-debugging-port=9222 --user-data-dir=$HOME/.openclaw/browser/chrome-profile`

## Environment
- Platform: WSL2 (Ubuntu) on Windows
- LLM Backend: LM Studio (local, Anthropic-compatible API)
- Embeddings: nomic-embed-text via LM Studio (OpenAI-compatible /v1/embeddings)
TOOLS_NEW
  fi
}

# ---------------------------------------------------------------------------
# Launch Chrome with CDP and open the OpenClaw dashboard.
# ---------------------------------------------------------------------------
launch_chrome_dashboard() {
  local chrome_bin=""
  if have google-chrome-stable; then
    chrome_bin="google-chrome-stable"
  elif have google-chrome; then
    chrome_bin="google-chrome"
  elif have chromium-browser; then
    chrome_bin="chromium-browser"
  elif have chromium; then
    chrome_bin="chromium"
  fi

  if [[ -z "$chrome_bin" ]]; then
    warn "Chrome not found in WSL2. Open the dashboard manually."
    return 0
  fi

  # Get the dashboard URL (includes access token)
  local dashboard_url=""
  local dashboard_output
  dashboard_output="$(openclaw dashboard --no-open 2>&1 || true)"
  dashboard_url="$(printf '%s' "$dashboard_output" | grep -oP 'https?://\S+' | head -1 || true)"

  # Fallback: extract token from config
  if [[ -z "$dashboard_url" ]] && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
    local gw_token
    gw_token="$(python3 -c "
import json, sys
from pathlib import Path
try:
    cfg = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    token = cfg.get('gateway', {}).get('auth', {}).get('token', '')
    if token:
        print(token)
except Exception:
    pass
" "$OPENCLAW_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$gw_token" ]]; then
      dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/#token=${gw_token}"
    fi
  fi

  if [[ -z "$dashboard_url" ]]; then
    dashboard_url="http://127.0.0.1:${OPENCLAW_AMD_GATEWAY_PORT}/"
    warn "Could not retrieve dashboard token. You may need to authenticate manually."
  fi

  local chrome_debug_port=9222
  local chrome_user_data="$HOME/.openclaw/browser/chrome-profile"
  mkdir -p "$chrome_user_data"

  info "Launching Chrome with CDP (port ${chrome_debug_port}) and opening dashboard"
  info "Dashboard: ${dashboard_url}"
  nohup "$chrome_bin" \
    --no-first-run \
    --no-default-browser-check \
    --remote-debugging-port="$chrome_debug_port" \
    --remote-allow-origins="*" \
    --user-data-dir="$chrome_user_data" \
    "$dashboard_url" >/dev/null 2>&1 &
  disown
}

print_summary() {
  printf '\n'
  info "${SCRIPT_NAME} ${SCRIPT_VERSION} complete"
  printf '  LM Studio endpoint : %s\n' "$LMSTUDIO_BASE_URL"
  printf '  Model              : %s\n' "$OPENCLAW_AMD_MODEL_ID"
  printf '  Context tokens     : %s\n' "$OPENCLAW_AMD_CONTEXT_TOKENS"
  printf '  Max tokens         : %s\n' "$OPENCLAW_AMD_MODEL_MAX_TOKENS"
  printf '  Agent concurrency  : %s\n' "$OPENCLAW_AMD_MAX_AGENTS"
  printf '  Subagent conc.     : %s\n' "$OPENCLAW_AMD_MAX_SUBAGENTS"
  printf '\n'
}

main() {
  print_banner
  require_linux

  # Risk acknowledgement — shown first, before any installs or changes
  printf '\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\033[1;33m  IMPORTANT — PLEASE READ BEFORE CONTINUING\033[0m\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\n'
  printf '\033[1;33mOpenClaw is a highly autonomous AI agent. Giving any AI agent\033[0m\n'
  printf '\033[1;33maccess to any system may result in the AI acting in unpredictable\033[0m\n'
  printf '\033[1;33mways with unpredictable/unforeseen outcomes. Use of any AMD\033[0m\n'
  printf '\033[1;33msuggested implementations is made at your own risk. AMD makes no\033[0m\n'
  printf '\033[1;33mrepresentations/warranties with your use of an AI agent as\033[0m\n'
  printf '\033[1;33mdescribed herein. Failure to exercise appropriate caution may\033[0m\n'
  printf '\033[1;33mresult in damages (foreseen and/or unforeseen).\033[0m\n'
  printf '\n'
  printf '\033[1;33m================================================================\033[0m\n'
  printf '\n'
  local accept=""
  read -r -p "Do you accept the risk and wish to continue? [y/N]: " accept < /dev/tty
  if [[ ! "$accept" =~ ^[Yy] ]]; then
    die "Risk not accepted. Exiting."
  fi
  printf '\n'

  apt_install_if_missing ca-certificates curl git python3 build-essential wget gnupg2
  prepare_npm_global_prefix
  install_homebrew_if_missing
  maybe_enable_wsl_systemd

  # LM Studio detection
  resolve_lmstudio_url
  wait_for_lmstudio
  select_lmstudio_model

  # Chrome (needed for OpenClaw browser control inside WSL2)
  install_chrome_if_missing

  # OpenClaw install
  install_or_update_openclaw
  prepare_npm_global_prefix
  require_openclaw

  # Onboard or skip if already configured
  local configured=0
  if is_openclaw_configured; then
    info "OpenClaw already configured for lmstudio/${OPENCLAW_AMD_MODEL_ID} — skipping onboard"
    configured=1
    RAN_ONBOARD=1
  else
    backup_openclaw_config "$OPENCLAW_CONFIG_FILE"
    if run_noninteractive_onboard "$LMSTUDIO_BASE_URL"; then
      configured=1
    else
      warn "Non-interactive onboard failed."
    fi
    (( configured == 1 )) || die "OpenClaw onboarding against LM Studio failed. Check the output above."
  fi

  auto_tune_config

  # Ensure DISPLAY is set for WSLg's X server (needed for Chrome in WSL2).
  # Persist to shell profiles so the OpenClaw agent's shells also have it.
  if [[ -S /tmp/.X11-unix/X0 ]]; then
    export DISPLAY=:0
    local display_line='export DISPLAY=:0'
    append_line_if_missing "$HOME/.profile" "$display_line"
    append_line_if_missing "$HOME/.bashrc" "$display_line"
    if [[ -f "$HOME/.zshrc" ]]; then
      append_line_if_missing "$HOME/.zshrc" "$display_line"
    fi
    info "DISPLAY=:0 set and persisted to shell profiles (WSLg X server detected)"
  fi

  # Interactive onboard pass — lets the user configure gateway, hooks, skills,
  # channels. Skips auth (already configured) and hatch (we do that in a 3rd pass).
  info "Launching interactive onboard for gateway, hooks, skills, and channels..."
  printf '\n'
  openclaw onboard --auth-choice skip --skip-ui < /dev/tty || warn "Interactive onboard exited with an error. You can re-run it later with: openclaw onboard"
  printf '\n'

  # Write browser environment info to TOOLS.md so the agent knows how to use Chrome
  write_tools_md

  # Build the memory search index (triggers embedding model connection to LM Studio)
  info "Building memory search index..."
  openclaw memory index 2>&1 || warn "Memory indexing failed. You can run it later with: openclaw memory index"

  print_summary

  # Final onboard pass — skip everything except the hatch (UI launch).
  # This preserves the original hatching experience.
  # Steps skipped: auth, web search, channels, skills, health check.
  # Daemon is opt-in (not passed), so it's implicitly skipped.
  info "Launching hatching..."
  printf '\n'
  openclaw onboard \
    --auth-choice skip \
    --accept-risk \
    --skip-search \
    --skip-skills \
    --skip-channels \
    --skip-daemon \
    --skip-health \
    < /dev/tty || warn "Hatching exited with an error. You can launch it later with: openclaw onboard"
}

main "$@"
