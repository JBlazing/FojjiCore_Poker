#!/usr/bin/env bash
# Checks run on every pipeline: Lua syntax, every TOC's file list and version, the engine tests,
# and (on tags) the version.
set -euo pipefail

ADDON_DIR="${ADDON_DIR:-FojjiCore_Poker}"
TOC="$ADDON_DIR/$ADDON_DIR.toc"
fail=0

[[ -f "$TOC" ]] || { echo "ERROR: $TOC not found"; exit 1; }

echo "== Lua 5.1 syntax check =="
while IFS= read -r -d '' f; do
  if ! luac5.1 -p "$f"; then
    fail=1
  fi
done < <(find "$ADDON_DIR" tests -name '*.lua' -print0)

toc_field() { grep -m1 "^## $2:" "$1" | sed "s/^## $2:[[:space:]]*//; s/\r\$//"; }

toc_version="$(toc_field "$TOC" Version)"
echo "TOC version: ${toc_version:-<missing>}"
[[ -n "$toc_version" ]] || { echo "ERROR: no '## Version:' line in $TOC"; fail=1; }

# The addon ships one TOC per client flavor (FojjiCore_Poker_TBC.toc, ..._Camelot.toc).
for toc in "$ADDON_DIR"/*.toc; do
  echo "== $toc =="
  # Every non-comment, non-blank line in the TOC is a file the game will load.
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    path="$ADDON_DIR/$(printf '%s' "$line" | sed 's#\\#/#g')"
    if [[ ! -f "$path" ]]; then
      echo "ERROR: $toc lists '$line' but $path does not exist"
      fail=1
    fi
  done < "$toc"
  v="$(toc_field "$toc" Version)"
  if [[ "$v" != "$toc_version" ]]; then
    echo "ERROR: $toc has version '${v:-<missing>}', $TOC has '$toc_version'. Keep them the same."
    fail=1
  fi
  [[ -n "$(toc_field "$toc" Interface)" ]] || { echo "ERROR: no '## Interface:' line in $toc"; fail=1; }
done

echo "== Engine tests =="
# tests/test_table.lua needs FojjiCore Games installed, so only the pure engine tests run here.
if ! lua5.1 tests/test_engine.lua; then
  fail=1
fi

if [[ -n "${CI_COMMIT_TAG:-}" ]]; then
  echo "== Tag check =="
  tag_version="${CI_COMMIT_TAG#v}"
  tag_version="${tag_version%%-*}" # drop -beta.1 / -alpha.1
  if [[ "$tag_version" != "$toc_version" ]]; then
    echo "ERROR: tag $CI_COMMIT_TAG does not match TOC version $toc_version."
    echo "       Update '## Version:' in every $ADDON_DIR/*.toc, commit, and re-tag."
    fail=1
  fi
fi

if (( fail )); then
  echo "Validation failed."
  exit 1
fi
echo "All checks passed."
