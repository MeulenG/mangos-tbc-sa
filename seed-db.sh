#!/usr/bin/env bash
#
# seed-db.sh — build the databases from scratch on a fresh server.
#
#   World DB  = upstream tbc-db base + upstream updates + YOUR custom SQL
#   realmd    = seeded empty from the core's SQL
#   characters= seeded empty from the core's SQL
#
# Idempotent-ish: safe to re-run, but see --wipe-world. It will NOT touch
# characters/realmd unless you pass --seed-auth, so you can't clobber live
# player data by accident once the realm is up.
#
# Usage:
#   ./seed-db.sh --world              # (re)build world DB only  [default]
#   ./seed-db.sh --world --wipe-world # drop & recreate world DB first
#   ./seed-db.sh --seed-auth          # ALSO create empty realmd + characters
#                                     #   (first install only — refuses if non-empty)
#   ./seed-db.sh --all                # world + auth (fresh install convenience)
#
set -euo pipefail

ENV_FILE="${MANGOS_ENV:-/opt/mangos/etc/mangos.env}"
[[ -f "$ENV_FILE" ]] || { echo "FATAL: env file not found: $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

DO_WORLD=0 DO_AUTH=0 WIPE_WORLD=0
[[ $# -eq 0 ]] && DO_WORLD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --world)      DO_WORLD=1 ;;
    --seed-auth)  DO_AUTH=1 ;;
    --all)        DO_WORLD=1; DO_AUTH=1 ;;
    --wipe-world) WIPE_WORLD=1 ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;34m[seed]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[seed]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[seed] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

MYSQL=(mysql --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" --password="$DB_PASS")
mysql_run()  { "${MYSQL[@]}" "$@"; }
mysql_db()   { "${MYSQL[@]}" "$1"; }   # pipe SQL on stdin into DB $1

# apply a single .sql file into a DB, failing loudly
apply_sql() { # $1=db  $2=file
  [[ -f "$2" ]] || die "SQL file missing: $2"
  log "  apply $(basename "$2")"
  mysql_db "$1" < "$2"
}

# apply every *.sql in a dir, in filename sort order
apply_dir() { # $1=db  $2=dir
  [[ -d "$2" ]] || { warn "  no dir $2 — skipping"; return 0; }
  local f found=0
  while IFS= read -r -d '' f; do
    found=1; apply_sql "$1" "$f"
  done < <(find "$2" -maxdepth 1 -name '*.sql' -print0 | sort -z)
  [[ $found -eq 1 ]] || warn "  no .sql files in $2"
}

row_count() { # $1=db -> echoes number of tables (0 if db absent/empty)
  mysql_run -N -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1';" 2>/dev/null || echo 0
}

backup_db() { # $1=db
  mkdir -p "$BACKUP_DIR"
  local out="$BACKUP_DIR/$1-$(date +%Y%m%d-%H%M%S).sql"
  log "  backup $1 -> $out"
  mysqldump --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    --password="$DB_PASS" --single-transaction --routines "$1" > "$out"
}

# ---------------------------------------------------------------------------
# WORLD DB
# ---------------------------------------------------------------------------
seed_world() {
  log "Seeding world DB: $DB_WORLD"

  if [[ $WIPE_WORLD -eq 1 ]]; then
    if [[ "$(row_count "$DB_WORLD")" != "0" ]]; then backup_db "$DB_WORLD"; fi
    warn "  DROP + CREATE $DB_WORLD"
    mysql_run -e "DROP DATABASE IF EXISTS \`$DB_WORLD\`;
                  CREATE DATABASE \`$DB_WORLD\` DEFAULT CHARSET utf8mb4;"
  else
    mysql_run -e "CREATE DATABASE IF NOT EXISTS \`$DB_WORLD\` DEFAULT CHARSET utf8mb4;"
  fi

  # --- 1. upstream base -----------------------------------------------------
  # tbc-db ships a full base dump. Layout has changed across versions; the two
  # common ones are handled here. Verify against YOUR checkout once.
  local BASE=""
  if   [[ -d "$TBCDB_DIR/Full_DB" ]];            then BASE="$TBCDB_DIR/Full_DB"
  elif [[ -d "$TBCDB_DIR/Database/World" ]];     then BASE="$TBCDB_DIR/Database/World"
  fi
  [[ -n "$BASE" ]] || die "Can't locate tbc-db base dump under $TBCDB_DIR — check the repo layout and edit seed_world()."
  log "  base dump: $BASE"
  # base is usually ONE large .sql; apply all .sql found there in order
  apply_dir "$DB_WORLD" "$BASE"

  # --- 2. upstream incremental updates -------------------------------------
  # tbc-db keeps post-release fixes in an updates dir. Skip silently if absent.
  for u in "$TBCDB_DIR/Updates" "$TBCDB_DIR/Database/Updates"; do
    [[ -d "$u" ]] && { log "  upstream updates: $u"; apply_dir "$DB_WORLD" "$u"; }
  done

  # --- 3. YOUR captured migrations (spell_template, future edits) -----------
  log "  custom migrations: $CUSTOM_SQL_DIR"
  apply_dir "$DB_WORLD" "$CUSTOM_SQL_DIR"

  log "World DB done. Tables: $(row_count "$DB_WORLD")"
}

# ---------------------------------------------------------------------------
# AUTH + CHARACTERS  (first install only)
# ---------------------------------------------------------------------------
seed_auth() {
  log "Seeding realmd + characters (empty)"

  # The core ships the schema for these. Path differs by core age:
  local CORE_SQL=""
  for c in "$SRC_DIR/sql/base" "$SRC_DIR/src/shared/Database" "$SRC_DIR/sql"; do
    [[ -d "$c" ]] && { CORE_SQL="$c"; break; }
  done
  [[ -n "$CORE_SQL" ]] || die "Can't find core SQL dir under $SRC_DIR — edit seed_auth()."
  log "  core SQL: $CORE_SQL"

  # realmd
  if [[ "$(row_count "$DB_REALMD")" != "0" ]]; then
    die "$DB_REALMD is NOT empty — refusing to seed. This looks like a live/used DB.
         Re-seeding auth after go-live would destroy accounts. Do it manually if you're sure."
  fi
  mysql_run -e "CREATE DATABASE IF NOT EXISTS \`$DB_REALMD\` DEFAULT CHARSET utf8mb4;"
  local realm_sql; realm_sql="$(find "$CORE_SQL" -iname '*realmd*.sql' | head -n1)"
  [[ -n "$realm_sql" ]] && apply_sql "$DB_REALMD" "$realm_sql" \
    || warn "  no realmd schema .sql found under $CORE_SQL — apply manually"

  # characters
  if [[ "$(row_count "$DB_CHARS")" != "0" ]]; then
    die "$DB_CHARS is NOT empty — refusing to seed. Re-seeding would destroy player data."
  fi
  mysql_run -e "CREATE DATABASE IF NOT EXISTS \`$DB_CHARS\` DEFAULT CHARSET utf8mb4;"
  local char_sql; char_sql="$(find "$CORE_SQL" -iname '*character*.sql' | head -n1)"
  [[ -n "$char_sql" ]] && apply_sql "$DB_CHARS" "$char_sql" \
    || warn "  no characters schema .sql found under $CORE_SQL — apply manually"

  warn "  Reminder: create the game account + set realmlist manually, and let the"
  warn "  PlayerBots module generate bot accounts/characters on the server — do NOT"
  warn "  import your dev bot characters."
}

# ---------------------------------------------------------------------------
[[ $DO_WORLD -eq 1 ]] && seed_world
[[ $DO_AUTH  -eq 1 ]] && seed_auth
log "Done."
