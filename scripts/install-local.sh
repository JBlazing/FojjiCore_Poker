#!/usr/bin/env bash
# Copy FojjiCore_Poker into a local WoW client's Interface/AddOns folder, replacing the installed
# copy so files deleted here don't linger in the game. /reload in game afterwards (restart the game
# the first time, or after adding a file).
#
# Usage: scripts/install-local.sh [flavor...] [-n|--dry-run]
#   flavor   WoW client folder: forever (default), anniversary, classic_era, ... or "all".
#            The addon needs FojjiCore Games 4.0.52 or newer in that client.
# Environment:
#   WOW_DIR  WoW install folder (default: D:/Games/World of Warcraft).
set -euo pipefail

WOW_DIR="${WOW_DIR:-D:/Games/World of Warcraft}"
ADDON_DIR=FojjiCore_Poker

die() { echo "ERROR: $*" >&2; exit 1; }
flavors=() dry=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) dry=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) flavors+=("$arg") ;;
  esac
done
((${#flavors[@]})) || flavors=(forever)

command -v cygpath >/dev/null && WOW_DIR="$(cygpath -u "$WOW_DIR")"
[[ -d "$WOW_DIR" ]] || die "WoW folder not found: $WOW_DIR (set WOW_DIR)"
cd "$(dirname "$0")/.."
[[ -f "$ADDON_DIR/$ADDON_DIR.toc" ]] || die "$ADDON_DIR/$ADDON_DIR.toc not found"

targets=()
for f in "${flavors[@]}"; do
  if [[ "$f" == all ]]; then
    for d in "$WOW_DIR"/_*_/Interface/AddOns; do [[ -d "$d" ]] && targets+=("$d"); done
    continue
  fi
  f="${f#_}"; f="${f%_}"
  d="$WOW_DIR/_${f}_/Interface/AddOns"
  [[ -d "$d" ]] || die "no Interface/AddOns folder for '$f' in $WOW_DIR"
  targets+=("$d")
done

version="$(grep -m1 '^## Version:' "$ADDON_DIR/$ADDON_DIR.toc" | sed 's/^## Version:[[:space:]]*//; s/\r$//')"
echo "Installing $ADDON_DIR $version"
for addons in "${targets[@]}"; do
  client="${addons%/Interface/AddOns}"; client="${client##*/}"
  games="$addons/FojjiCore_Games/FojjiCore_Games.toc"
  if [[ ! -f "$games" ]]; then
    echo "  $client: skipped (FojjiCore Games isn't installed there)"; continue
  fi
  if ! grep -q "Games.Register" "$addons/FojjiCore_Games/Games.lua" 2>/dev/null; then
    echo "  $client: warning, FojjiCore Games there is older than 4.0.52; the addon will switch itself off"
  fi
  dest="$addons/$ADDON_DIR"
  if ((dry)); then echo "  [dry run] $client: would replace $dest"; continue; fi
  tmp="$addons/.$ADDON_DIR.installing"
  rm -rf "$tmp"
  cp -R "$ADDON_DIR" "$tmp"
  [[ -f LICENSE ]] && cp LICENSE "$tmp/LICENSE"
  rm -rf "$dest"
  mv "$tmp" "$dest"
  echo "  $client: $dest"
done
echo "Done."
