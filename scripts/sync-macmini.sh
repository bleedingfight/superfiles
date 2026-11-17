#!/usr/bin/env bash
# Two-way sync of this repo with macmini:~/super-files.
#
# Newer file wins, nothing is ever deleted (no --delete). Build artifacts and
# dependency trees are filtered out by scripts/rsync-exclude.txt, so what moves
# is source only.
#
# Usage:
#   ./scripts/sync-macmini.sh              # both directions
#   ./scripts/sync-macmini.sh --pull       # mac -> here
#   ./scripts/sync-macmini.sh --push       # here -> mac
#   ./scripts/sync-macmini.sh -n           # dry run, just list what moves
#
# Env: REMOTE (default macmini), REMOTE_DIR (default super-files)
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE=${REMOTE:-macmini}
REMOTE_DIR=${REMOTE_DIR:-super-files}
EXCL=scripts/rsync-exclude.txt

DRY=0
MODE=both
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=1 ;;
    --pull) MODE=pull ;;
    --push) MODE=push ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

[[ -f $EXCL ]] || { echo "missing $EXCL" >&2; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE" true \
  || { echo "cannot ssh to $REMOTE" >&2; exit 1; }

# -u: newer file wins, so a stale copy can't clobber the other side
# -c: compare content, not just size+mtime, so equal-timestamp edits are caught
OPTS=(-rlptuc --exclude-from="$EXCL" --itemize-changes)
(( DRY )) && OPTS+=(-n)

run() { # run <from> <to> <label>
  local stats
  stats=$(rsync "${OPTS[@]}" --stats "$1" "$2" 2>&1)
  echo "$stats" | grep -E '^(<|>)f' | sed 's/^/  /' || true
  echo "  [${3:-sync}] $(echo "$stats" | grep -oE 'Number of regular files transferred: [0-9,]+' | grep -oE '[0-9,]+$') file(s)"
  # -u skipping a file that differs is worth surfacing: it means the other side
  # was edited but its mtime is older, so the sync deliberately left it alone.
}

(( DRY )) && echo "DRY RUN (nothing written)"
case $MODE in
  both)
    echo "== pull: $REMOTE:~/$REMOTE_DIR -> ."
    run "$REMOTE:~/$REMOTE_DIR/" ./ pull
    echo "== push: . -> $REMOTE:~/$REMOTE_DIR"
    run ./ "$REMOTE:~/$REMOTE_DIR/" push
    ;;
  pull) run "$REMOTE:~/$REMOTE_DIR/" ./ pull ;;
  push) run ./ "$REMOTE:~/$REMOTE_DIR/" push ;;
esac
