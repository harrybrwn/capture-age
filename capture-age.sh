#!/usr/bin/env bash
#
# capture-age.sh - install and run CaptureAge (Windows/Electron app) for AoE2 DE
#                  inside Steam's Proton container.
#
#   ./capture-age.sh                 launch CaptureAge
#   ./capture-age.sh install         download the vendor installer and run it into the prefix
#   ./capture-age.sh status          show resolved paths and installed version
#   ./capture-age.sh --help
#
# Everything lives outside Steam's own game prefixes:
#
#   $CA_HOME/pfx/...                 dedicated Wine prefix (Proton "Proton Hotfix")
#   $CA_HOME/CaptureAgeSetup.exe     cached vendor web-installer stub
#
# Overridable environment:
#   CA_HOME          default: ${XDG_DATA_HOME:-~/.local/share}/capture-age
#   CA_STEAM         default: ~/.local/share/Steam
#   CA_PROTON        default: $CA_STEAM/steamapps/common/Proton Hotfix
#   CA_RUNTIME       default: $CA_STEAM/steamapps/common/SteamLinuxRuntime_4
#   CA_AOE_DIR       AoE2 DE install dir (default: auto-detect via libraryfolders.vdf)
#   CA_AOE_APPID     default: 813780
#
set -euo pipefail

log()  { printf '[capture-age] %s\n' "$*" >&2; }
die()  { printf '[capture-age] error: %s\n' "$*" >&2; exit 1; }

CA_HOME=${CA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/capture-age}
CA_STEAM=${CA_STEAM:-$HOME/.local/share/Steam}
CA_PROTON=${CA_PROTON:-$CA_STEAM/steamapps/common/Proton Hotfix}
CA_RUNTIME=${CA_RUNTIME:-$CA_STEAM/steamapps/common/SteamLinuxRuntime_4}
CA_AOE_APPID=${CA_AOE_APPID:-813780}
CA_PREFIX=$CA_HOME/pfx
CA_SETUP=${CA_SETUP:-$CA_HOME/CaptureAgeSetup.exe}
CA_SETUP_URL=${CA_SETUP_URL:-https://captureage.com/api/cade/download/prod/CaptureAgeSetup.exe}

# CaptureAge's native addon (resources/app/cade.node) crashes during DllMain when it
# initialises against Microsoft's bundled VC++ 14.28 runtime inside Wine. Wine's own
# builtin CRT is ABI compatible and consistent with Wine's builtin ucrtbase.
CA_DLL_OVERRIDES="msvcp140=b;vcruntime140=b;vcruntime140_1=b;concrt140=b"

CA_ENV=()
ENV_AOE_DIR=

usage() {
  cat <<'EOF'
capture-age.sh - install and run CaptureAge (Windows/Electron app) for AoE2 DE
                 inside Steam's Proton container.

  ./capture-age.sh                 launch CaptureAge
  ./capture-age.sh install         download the vendor installer and run it into the prefix
  ./capture-age.sh status          show resolved paths and installed version
  ./capture-age.sh --help

Everything lives outside Steam's own game prefixes:

  $CA_HOME/pfx/...                 dedicated Wine prefix (Proton "Proton Hotfix")
  $CA_HOME/CaptureAgeSetup.exe     cached vendor web-installer stub

Overridable environment:
  CA_HOME          default: ${XDG_DATA_HOME:-~/.local/share}/capture-age
  CA_STEAM         default: ~/.local/share/Steam
  CA_PROTON        default: $CA_STEAM/steamapps/common/Proton Hotfix
  CA_RUNTIME       default: $CA_STEAM/steamapps/common/SteamLinuxRuntime_4
  CA_AOE_DIR       AoE2 DE install dir (default: auto-detect via libraryfolders.vdf)
  CA_AOE_APPID     default: 813780
EOF
}

# --- environment detection -------------------------------------------------

# Find the AoE2 DE install dir. CaptureAge asks Steam for it and gets a path on
# the S: drive, which Proton only maps when STEAM_COMPAT_INSTALL_PATH is set.
resolve_aoe_dir() {
  local vdf lib
  if [ -n "${CA_AOE_DIR:-}" ] && [ -d "${CA_AOE_DIR:-}" ]; then
    ENV_AOE_DIR=$CA_AOE_DIR
    return 0
  fi
  vdf=$CA_STEAM/steamapps/libraryfolders.vdf
  if [ -f "$vdf" ]; then
    while IFS= read -r lib; do
      if [ -d "$lib/steamapps/common/AoE2DE" ]; then
        ENV_AOE_DIR=$lib/steamapps/common/AoE2DE
        return 0
      fi
    done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)".*/\1/p' "$vdf")
  fi
  if [ -d "$CA_STEAM/steamapps/common/AoE2DE" ]; then
    ENV_AOE_DIR=$CA_STEAM/steamapps/common/AoE2DE
    return 0
  fi
  return 1
}

find_ca_exe() {
  find "$CA_PREFIX/drive_c/users" -maxdepth 6 -type f \
       -path '*/AppData/Local/Programs/CaptureAge/CaptureAge.exe' -print -quit 2>/dev/null
}

find_ca_version() {
  local exe pkg
  exe=$(find_ca_exe) || return 0
  pkg=$(dirname "$exe")/resources/app/package.json
  [ -f "$pkg" ] && sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg" | head -1
}

ca_user_dir() {
  local d
  for d in "$CA_PREFIX/drive_c/users"/*; do
    [ -d "$d/AppData" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# CaptureAge wants a Windows path for the game dir. Proton maps S: to the game's
# Steam library when STEAM_COMPAT_INSTALL_PATH is set, which is what the app's own
# Steam lookup reports, so prefer that. Fall back to Z: (host root).
aoe_win_path() {
  local lib suffix
  [ -n "$ENV_AOE_DIR" ] || return 1
  if [[ $ENV_AOE_DIR == */steamapps/common/* ]]; then
    lib=${ENV_AOE_DIR%%/steamapps/common/*}
    suffix=${ENV_AOE_DIR#"$lib"/}
    printf 'S:\\%s\n' "$(printf '%s' "$suffix" | tr '/' '\\')"
  else
    printf 'Z:%s\n' "$(printf '%s' "$ENV_AOE_DIR" | tr '/' '\\')"
  fi
}

# CaptureAge starts with the *stored* game directory and only falls back to its
# built-in default (C:\Program Files (x86)\Steam\...), which does not exist in
# our prefix. A bad first start leaves the app stuck on an error dialog, so seed
# the state file before launching. The state carries a migration version; keep
# whatever the app already wrote and only add a default on first run.
seed_game_dir() {
  local udir state wpath
  udir=$(ca_user_dir) || return 0
  state=$udir/AppData/Roaming/CaptureAge/persistedState_prod.json
  wpath=$(aoe_win_path) || return 0
  command -v python3 >/dev/null || { log "warning: python3 not found, cannot pre-seed game directory"; return 0; }
  if python3 - "$state" "$wpath" "0.0.46" <<'PY'
import json, os, sys
path, value, default_version = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
internal = data.get('__internal__')
if not isinstance(internal, dict):
    internal = {}
migrations = internal.get('migrations')
if not isinstance(migrations, dict) or 'version' not in migrations:
    migrations = {'version': default_version}
internal['migrations'] = migrations
data['__internal__'] = internal
if data.get('lastUsedGameDirectory') == value:
    sys.exit(1)
data['lastUsedGameDirectory'] = value
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(data, f)
os.replace(tmp, path)
PY
  then
    log "seeded game directory: $wpath"
  fi
}

# Expose the AoE2 profile dir (replays, mods, ...) inside our prefix. CaptureAge
# reads replays/mods from %USERPROFILE%\Games\Age of Empires 2 DE\<steamid>.
link_aoe_userdata() {
  local aoe_pfx src user dst
  aoe_pfx=$CA_STEAM/steamapps/compatdata/$CA_AOE_APPID/pfx
  [ -d "$aoe_pfx/drive_c/users" ] || return 0
  src=$(find "$aoe_pfx/drive_c/users" -maxdepth 3 -type d \
             -name 'Age of Empires 2 DE' -print -quit 2>/dev/null)
  [ -n "$src" ] || return 0
  for user in "$CA_PREFIX/drive_c/users"/*; do
    [ -d "$user/AppData" ] || continue
    dst="$user/Games/Age of Empires 2 DE"
    if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      log "linked AoE2 user data: ${dst#"$CA_PREFIX"/} -> $src"
    fi
  done
}

# --- Proton ---------------------------------------------------------------

proton_run() {
  local launcher=()
  if [ -x "$CA_RUNTIME/_v2-entry-point" ] && [ -x "$CA_PROTON/proton" ]; then
    launcher=("$CA_RUNTIME/_v2-entry-point" --verb=waitforexitandrun -- "$CA_PROTON/proton" run)
  elif [ -x "$CA_PROTON/proton" ]; then
    launcher=("$CA_PROTON/proton" run)
  else
    die "found neither '$CA_RUNTIME/_v2-entry-point' nor '$CA_PROTON/proton'"
  fi
  env -u WINEPREFIX \
      STEAM_COMPAT_CLIENT_INSTALL_PATH="$CA_STEAM" \
      STEAM_COMPAT_DATA_PATH="$CA_HOME" \
      STEAM_COMPAT_INSTALL_PATH="${ENV_AOE_DIR:-$CA_STEAM/steamapps/common/AoE2DE}" \
      STEAM_COMPAT_LIBRARY_PATHS="$CA_STEAM/steamapps" \
      WINEDEBUG="${WINEDEBUG:--all}" \
      ${CA_ENV[@]+"${CA_ENV[@]}"} \
      ${launcher[@]+"${launcher[@]}"} "$@"
}

# --- commands -------------------------------------------------------------

do_install() {
  resolve_aoe_dir || log "warning: AoE2 DE install not found; set CA_AOE_DIR if auto-detect is wrong"
  if [ ! -x "$CA_PROTON/proton" ]; then
    die "Proton tool not found at '$CA_PROTON'"
  fi
  mkdir -p "$CA_HOME"

  if [ ! -f "$CA_SETUP" ]; then
    if [ -f "$(dirname "$0")/CaptureAgeSetup.exe" ]; then
      CA_SETUP=$(cd "$(dirname "$0")" && pwd)/CaptureAgeSetup.exe
    else
      log "downloading vendor installer stub"
      curl -fL --progress-bar -o "$CA_SETUP.part" "$CA_SETUP_URL"
      mv "$CA_SETUP.part" "$CA_SETUP"
    fi
  fi

  log "running silent install (the stub downloads ~150 MB inside the prefix)"
  proton_run "$CA_SETUP" /S

  local exe
  exe=$(find_ca_exe) || die "installer finished but CaptureAge.exe was not found under '$CA_PREFIX'"
  link_aoe_userdata
  seed_game_dir
  log "installed CaptureAge $(find_ca_version) -> $exe"
}

do_run() {
  local exe
  exe=$(find_ca_exe) || die "CaptureAge is not installed in '$CA_HOME' (run: $0 install)"
  if ! resolve_aoe_dir; then
    die "could not locate the AoE2 DE install dir (set CA_AOE_DIR) - CaptureAge needs it on the S: drive"
  fi
  link_aoe_userdata
  seed_game_dir
  CA_ENV=(WINEDLLOVERRIDES="$CA_DLL_OVERRIDES")
  log "launching CaptureAge $(find_ca_version) from $exe"
  proton_run "$exe" "$@"
}

do_status() {
  local exe version
  exe=$(find_ca_exe || true)
  version=$(find_ca_version || true)
  printf 'prefix:       %s\n' "$CA_PREFIX"
  printf 'installed:    %s\n' "${exe:-<not installed>}"
  printf 'version:      %s\n' "${version:-?}"
  printf 'Steam:        %s\n' "$CA_STEAM"
  printf 'Proton:       %s\n' "$CA_PROTON"
  printf 'runtime:      %s\n' "$CA_RUNTIME"
  printf 'AoE2 DE:      %s\n' "$(resolve_aoe_dir && printf '%s' "$ENV_AOE_DIR" || printf '<not found>')"
  local ud="$CA_PREFIX/drive_c/users/steamuser/Games/Age of Empires 2 DE"
  if [ -L "$ud" ]; then
    printf 'game userdata: %s\n' "$(readlink "$ud")"
  elif [ -e "$ud" ]; then
    printf 'game userdata: %s (real dir)\n' "$ud"
  else
    printf 'game userdata: <not linked>\n'
  fi
}

case "${1:-run}" in
  run)      shift || true; do_run "$@" ;;
  install)  do_install ;;
  status)   do_status ;;
  -h|--help|help) usage ;;
  *)        die "unknown command '$1' (try --help)" ;;
esac
