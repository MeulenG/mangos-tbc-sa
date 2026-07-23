#!/usr/bin/env bash
#
# deploy.sh — build a tagged release and swap it in atomically.
#
# Two tiers, matching your dlopen architecture:
#   full    : core (+ everything) changed -> build, migrate, restart world
#   plugin  : bot-logic-only change -> rebuild ONLY the .so, GM-reload, no restart
#
# Usage:
#   ./deploy.sh v1.0.0                 # full release from tag v1.0.0
#   ./deploy.sh v1.0.0 --skip-migrate  # full build but don't touch the DB
#   ./deploy.sh v1.0.0 --plugin-only   # fast path: plugin .so only, zero downtime
#   ./deploy.sh --rollback             # repoint 'current' to previous release + restart
#   ./deploy.sh --list                 # show releases and which is active
#
# Refuses to build from a dirty / non-tag tree (see git describe --exact-match).
#
set -euo pipefail

ENV_FILE="${MANGOS_ENV:-/opt/mangos/etc/mangos.env}"
[[ -f "$ENV_FILE" ]] || { echo "FATAL: env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deploy] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

TAG="" PLUGIN_ONLY=0 SKIP_MIGRATE=0 ACTION="deploy"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-only) PLUGIN_ONLY=1 ;;
    --skip-migrate) SKIP_MIGRATE=1 ;;
    --rollback)    ACTION="rollback" ;;
    --list)        ACTION="list" ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    v*|V*)         TAG="$1" ;;
    *)             echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- helpers ---------------------------------------------------------------
active_release() { readlink -f "$CURRENT_LINK" 2>/dev/null || true; }

list_releases() {
  log "Releases in $RELEASES_DIR:"
  local cur; cur="$(active_release)"
  for d in "$RELEASES_DIR"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    local mark="  "; [[ "$d" == "$cur" ]] && mark="=>"
    printf '  %s %s\n' "$mark" "$(basename "$d")"
    [[ -f "$d/RELEASE.txt" ]] && sed 's/^/        /' "$d/RELEASE.txt"
  done
}

backup_world() {
  mkdir -p "$BACKUP_DIR"
  local out="$BACKUP_DIR/${DB_WORLD}-predeploy-$(date +%Y%m%d-%H%M%S).sql"
  log "Backing up world DB -> $out"
  mysqldump --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    --password="$DB_PASS" --single-transaction --routines "$DB_WORLD" > "$out"
}

apply_migrations() {
  [[ -d "$CUSTOM_SQL_DIR" ]] || { warn "no custom SQL dir; nothing to migrate"; return 0; }
  log "Applying migrations from $CUSTOM_SQL_DIR (idempotent)"
  local f
  while IFS= read -r -d '' f; do
    log "  $(basename "$f")"
    mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
      --password="$DB_PASS" "$DB_WORLD" < "$f"
  done < <(find "$CUSTOM_SQL_DIR" -maxdepth 1 -name '*.sql' -print0 | sort -z)
}

checkout_tag() {
  [[ -n "$TAG" ]] || die "no tag given (e.g. ./deploy.sh v1.0.0)"
  log "Fetching + checking out $TAG"
  git -C "$SRC_DIR" fetch --tags --prune
  git -C "$SRC_DIR" checkout -q "$TAG"
  git -C "$SRC_DIR" submodule update --init --recursive   # pin plugin/other submodules
  # refuse to build junk: tree must be clean AND exactly on a tag
  git -C "$SRC_DIR" diff --quiet && git -C "$SRC_DIR" diff --cached --quiet \
    || die "working tree is dirty after checkout — refusing to build a non-reproducible release"
  git -C "$SRC_DIR" describe --exact-match --tags >/dev/null 2>&1 \
    || die "HEAD is not exactly on a tag — refusing"
}

stamp_release() { # $1=release dir
  {
    echo "tag=$TAG"
    echo "core=$(git -C "$SRC_DIR" describe --tags --always --dirty)"
    echo "db=$(git -C "$TBCDB_DIR" describe --tags --always 2>/dev/null || echo n/a)"
    echo "built=$(date -Is)"
    echo "host=$(hostname)"
  } > "$1/RELEASE.txt"
  log "Stamped $1/RELEASE.txt"
}

# --- graceful restart (never kill -9 a live world) -------------------------
# The systemd unit's ExecStop should issue a save+shutdown; systemctl restart
# then blocks on that. This just triggers it.
restart_world() {
  log "Restarting $SVC_WORLD (graceful save via unit ExecStop)"
  sudo systemctl restart "$SVC_WORLD"
}

reload_plugin() {
  warn "Plugin .so replaced. Trigger the in-game GM reload command to hot-swap it."
  warn "(No restart issued — players stay connected.)"
}

# ---------------------------------------------------------------------------
case "$ACTION" in
  list)     list_releases; exit 0 ;;
  rollback)
    cur="$(active_release)"
    prev="$(ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | grep -vFx "$cur/" | head -n1 || true)"
    [[ -n "$prev" ]] || die "no previous release to roll back to"
    prev="${prev%/}"
    warn "Rolling back: $(basename "$cur") -> $(basename "$prev")"
    ln -sfn "$prev" "$CURRENT_LINK"
    restart_world
    log "Rolled back to $(basename "$prev")"
    exit 0 ;;
esac

# --- PLUGIN-ONLY FAST PATH -------------------------------------------------
if [[ $PLUGIN_ONLY -eq 1 ]]; then
  REL="$(active_release)"
  [[ -n "$REL" && -d "$REL" ]] || die "no active release to drop a plugin into"
  log "Plugin-only build against active release $(basename "$REL")"
  # Assumes a dedicated CMake target for the plugin .so. Adjust target name.
  cmake -S "$SRC_DIR" -B "$SRC_DIR/build" $CMAKE_EXTRA >/dev/null
  cmake --build "$SRC_DIR/build" --target playerbots_plugin -j"$BUILD_JOBS"
  # locate freshly built .so and copy into the live release's plugin dir
  so="$(find "$SRC_DIR/build" -name '*.so' -newer "$REL/RELEASE.txt" | head -n1)"
  [[ -n "$so" ]] || die "no freshly built .so found — check the plugin target name"
  install -m 0755 "$so" "$REL/plugins/"    # adjust dest to your loader's search path
  log "Installed $(basename "$so") -> $REL/plugins/"
  reload_plugin
  exit 0
fi

# --- FULL RELEASE ----------------------------------------------------------
checkout_tag
REL="$RELEASES_DIR/$TAG"
[[ -e "$REL" ]] && die "release dir already exists: $REL (bump the tag, or rm to rebuild)"
mkdir -p "$REL"

log "Configuring + building (jobs=$BUILD_JOBS)"
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
  -DCMAKE_INSTALL_PREFIX="$REL" $CMAKE_EXTRA
cmake --build "$SRC_DIR/build" -j"$BUILD_JOBS"
cmake --install "$SRC_DIR/build"

# shared, per-server resources: link in, don't copy per release
log "Linking shared config + client data"
mkdir -p "$REL/etc"
ln -sf "$ETC_DIR/mangosd.conf" "$REL/etc/mangosd.conf"
ln -sf "$ETC_DIR/realmd.conf"  "$REL/etc/realmd.conf"
ln -sfn "$DATA_DIR"            "$REL/data"

stamp_release "$REL"

# DB migrations happen BEFORE the swap, after a backup
if [[ $SKIP_MIGRATE -eq 0 ]]; then
  backup_world
  apply_migrations
else
  warn "Skipping DB migrations (--skip-migrate)"
fi

# atomic swap + graceful restart
log "Swapping 'current' -> $TAG"
ln -sfn "$REL" "$CURRENT_LINK"
restart_world

# prune old releases, keep the active one
log "Pruning old releases (keep $KEEP_RELEASES)"
cur="$(active_release)"
ls -1dt "$RELEASES_DIR"/*/ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  old="${old%/}"
  [[ "$old" == "$cur" ]] && continue
  warn "  rm $(basename "$old")"; rm -rf "$old"
done

log "Deployed $TAG. Active: $(basename "$(active_release)")"
