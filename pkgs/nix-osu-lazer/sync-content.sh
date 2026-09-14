# shellcheck shell=bash
# Download the declarative beatmap sets and skins osu!lazer has not imported.
#
# Usage: nix-osu-lazer-sync-content <beatmaps-manifest> <skins-manifest> <game-dir> <state-dir>
# Manifests are plain text, one set ID or .osk URL per line (# comments and
# blanks ignored). Pass /dev/null to skip one.
#
# osu!lazer keeps beatmaps and skins in its realm database, which nothing
# outside the game can write, so this script only downloads. Each archive waits
# in <state-dir>/import and its path is printed on stdout; the launcher hands
# those paths to osu!, which deletes an archive once it has imported it.
#
# osu! stores every file under files/ by its SHA-256. The hashes of an
# archive's files are recorded when it is downloaded, and it counts as imported
# for as long as all of them are stored, so a wiped data directory brings
# everything back. Sets are checked by their .osu files. Skins are checked by
# everything except skin.ini, which osu! rewrites on import.
#
# Beatmap mirrors are probed at runtime and missing sets are downloaded in one
# parallel aria2 run spread across the mirrors that answered. Failures retry on
# the next mirror.

set -euo pipefail

beatmaps_file="${1:-}"
skins_file="${2:-}"
game_dir="${3:?osu! data directory}"
state_dir="${4:?state directory}"

UA='nix-osu-lazer (https://github.com/gaavin/nix-osu-lazer)'
CANARY_ID=75
# Concurrent files in one aria2 process. High enough to saturate several
# mirrors, low enough to stay under typical burst limits (osu.direct is 10).
BATCH_JOBS=12

# Prefer no-video endpoints when a mirror has one.
BEATMAP_MIRRORS=(
  'https://catboy.best/d/{id}n'
  'https://osu.direct/api/d/{id}n'
  'https://api.nerinyan.moe/d/{id}?nv=true'
  'https://beatconnect.io/b/{id}'
  'https://dl.sayobot.cn/beatmaps/download/novideo/{id}'
)

files_dir="$game_dir/files"
import_dir="$state_dir/import"
hashes_dir="$state_dir/hashes"
working_mirrors=()
work=""

info() { printf 'nix-osu-lazer: %s\n' "$*" >&2; }
warn() { printf 'nix-osu-lazer: %s\n' "$*" >&2; }

cleanup() {
  if [ -n "$work" ]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

is_zip() {
  local f="$1"
  [ -s "$f" ] && [ "$(head -c 2 "$f")" = "PK" ]
}

mirror_host() {
  local u="$1"
  u="${u#http://}"
  u="${u#https://}"
  printf '%s' "${u%%/*}"
}

# --enable-http-keep-alive=false: aria2 otherwise reuses the TLS session across
# a 302 to a different hostname on the same IP (osu.direct → storage.osu.direct)
# and Cloudflare returns 403.
# --use-head=false: several mirrors stall or lie on HEAD.
# --no-conf: ignore the user's aria2.conf.
aria2_flags=(
  --no-conf
  -x5
  -s5
  --min-split-size=1M
  --file-allocation=none
  --allow-overwrite=true
  --auto-file-renaming=false
  --remove-control-file=true
  --always-resume=false
  --use-head=false
  --enable-http-keep-alive=false
  --max-tries=3
  --retry-wait=2
  --connect-timeout=8
  --timeout=45
  --user-agent="$UA"
  --console-log-level=error
  --summary-interval=0
  --download-result=hide
  --quiet=true
)

aria2_get() {
  local dest="$1" url="$2"
  aria2c "${aria2_flags[@]}" \
    --dir="$(dirname "$dest")" \
    --out="$(basename "$dest")" \
    "$url"
}

# One aria2 process; all URLs queued, up to BATCH_JOBS in flight, -x5 each.
aria2_batch() {
  local input="$1" count="$2" jobs
  [ "$count" -gt 0 ] || return 0
  jobs="$count"
  if [ "$jobs" -gt "$BATCH_JOBS" ]; then
    jobs="$BATCH_JOBS"
  fi
  aria2c "${aria2_flags[@]}" \
    -j"$jobs" \
    --input-file="$input"
}

probe_one_mirror() {
  local template="$1" out="$2" url tmp
  url="${template//\{id\}/$CANARY_ID}"
  tmp="$(mktemp)"
  # Only need zip magic; do not pull a full canary .osz.
  curl -sS -L --connect-timeout 3 --max-time 6 --range 0-7 --max-filesize 8192 \
    -A "$UA" -o "$tmp" "$url" >/dev/null 2>&1 || true
  if [ "$(head -c 2 "$tmp" 2>/dev/null || true)" = "PK" ]; then
    printf '%s\n' "$template" >"$out"
  else
    : >"$out"
  fi
  rm -f "$tmp"
}

probe_mirrors() {
  local probe_dir template i out hosts
  working_mirrors=()
  probe_dir="$(mktemp -d)"
  i=0
  for template in "${BEATMAP_MIRRORS[@]}"; do
    probe_one_mirror "$template" "$probe_dir/$i" &
    i=$((i + 1))
  done
  wait || true
  i=0
  for template in "${BEATMAP_MIRRORS[@]}"; do
    out="$probe_dir/$i"
    if [ -s "$out" ]; then
      working_mirrors+=("$template")
    else
      info "mirror skip: $(mirror_host "$template")"
    fi
    i=$((i + 1))
  done
  rm -rf "$probe_dir"
  if [ "${#working_mirrors[@]}" -eq 0 ]; then
    warn "no beatmap mirrors responded; beatmap sync will be skipped"
    return 0
  fi
  hosts=""
  for template in "${working_mirrors[@]}"; do
    hosts="$hosts $(mirror_host "$template")"
  done
  info "using ${#working_mirrors[@]} beatmap mirror(s):$hosts"
}

# record_hashes <archive> <list> <find tests...>
# Writes the SHA-256 of every file in the archive matching the find tests.
# osu! never stores a file with __MACOSX, .DS_Store or Thumbs.db anywhere in
# its path, so those are left out too.
record_hashes() {
  local archive="$1" list="$2" tree
  shift 2
  tree="$(mktemp -d)"
  if ! unzip -qq -o "$archive" -d "$tree" >/dev/null 2>&1; then
    rm -rf "$tree"
    return 1
  fi
  mkdir -p "$(dirname "$list")"
  find "$tree" -type f \
    ! -ipath "$tree/*__MACOSX*" ! -ipath "$tree/*.DS_Store*" ! -ipath "$tree/*Thumbs.db*" \
    "$@" -exec sha256sum --zero {} + | cut -z -d' ' -f1 | tr '\0' '\n' | sort -u >"$list.tmp"
  rm -rf "$tree"
  if [ ! -s "$list.tmp" ]; then
    rm -f "$list.tmp"
    return 1
  fi
  mv -f "$list.tmp" "$list"
}

# Imported while every recorded file is in osu!'s file store.
imported() {
  local list="$1" hash
  [ -s "$list" ] || return 1
  while IFS= read -r hash; do
    [ -e "$files_dir/${hash:0:1}/${hash:0:2}/$hash" ] || return 1
  done <"$list"
}

queue() {
  printf '%s\n' "$1"
}

beatmap_ids=()
collect_beatmap() { beatmap_ids+=("$1"); }

run_beatmaps() {
  local id i n round jobs input template url hosts archive list
  local -a missing=() remaining next

  [ "${#beatmap_ids[@]}" -gt 0 ] || return 0
  mkdir -p "$import_dir/beatmaps"

  for id in "${beatmap_ids[@]}"; do
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
      warn "skipping invalid beatmap set id: $id"
      continue
    fi
    archive="$import_dir/beatmaps/$id.osz"
    list="$hashes_dir/beatmaps/$id"
    if imported "$list"; then
      rm -f "$archive"
    elif [ -s "$list" ] && is_zip "$archive"; then
      queue "$archive"
    else
      missing+=("$id")
    fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0

  probe_mirrors
  [ "${#working_mirrors[@]}" -gt 0 ] || return 0

  hosts=""
  for template in "${working_mirrors[@]}"; do
    hosts="$hosts $(mirror_host "$template")"
  done

  work="$(mktemp -d "$import_dir/.download.XXXXXX")"
  remaining=("${missing[@]}")
  n="${#working_mirrors[@]}"
  round=0
  while [ "${#remaining[@]}" -gt 0 ] && [ "$round" -lt "$n" ]; do
    jobs="${#remaining[@]}"
    info "downloading $jobs set(s) across$hosts (round $((round + 1))/$n)"
    input="$work/aria2.round-$round"
    : >"$input"
    i=0
    for id in "${remaining[@]}"; do
      template="${working_mirrors[$(((i + round) % n))]}"
      url="${template//\{id\}/$id}"
      printf '%s\n  dir=%s\n  out=%s.osz\n\n' "$url" "$work" "$id" >>"$input"
      i=$((i + 1))
    done
    aria2_batch "$input" "$jobs" || true
    next=()
    for id in "${remaining[@]}"; do
      rm -f "$work/$id.osz.aria2"
      if is_zip "$work/$id.osz"; then
        continue
      fi
      rm -f "$work/$id.osz"
      next+=("$id")
    done
    remaining=("${next[@]}")
    round=$((round + 1))
  done

  for id in "${missing[@]}"; do
    archive="$import_dir/beatmaps/$id.osz"
    if is_zip "$work/$id.osz" \
      && record_hashes "$work/$id.osz" "$hashes_dir/beatmaps/$id" -iname '*.osu'; then
      mv -f "$work/$id.osz" "$archive"
      info "downloaded beatmap set $id"
      queue "$archive"
    else
      warn "failed to download beatmap set $id (mirrors missing or network error)"
    fi
  done
  rm -rf "$work"
  work=""
}

# osu! appends the archive's name to a skin's name, so keep the name the URL gives.
skin_archive_name() {
  local name="$1"
  name="${name%%[?#]*}"
  name="${name##*/}"
  name="$(printf '%b' "${name//%/\\x}" | tr -d '[:cntrl:]')"
  name="${name//\//}"
  name="${name//\\/}"
  name="${name%.[Oo][Ss][Kk]}"
  printf '%s.osk' "${name:-skin}"
}

install_skin() {
  local url="$1" key dir list archive tmp
  case "$url" in
    http://* | https://*) ;;
    *)
      warn "skipping invalid skin URL: $url"
      return 0
      ;;
  esac

  key="$(printf '%s' "$url" | sha256sum | cut -c1-16)"
  dir="$import_dir/skins/$key"
  list="$hashes_dir/skins/$key"
  archive="$dir/$(skin_archive_name "$url")"

  if imported "$list"; then
    rm -rf "$dir"
    return 0
  fi
  if [ -s "$list" ] && is_zip "$archive"; then
    queue "$archive"
    return 0
  fi

  info "downloading skin $url"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.download.XXXXXX")"
  if aria2_get "$tmp" "$url" && is_zip "$tmp" \
    && record_hashes "$tmp" "$list" ! -iname 'skin.ini'; then
    mv -f "$tmp" "$archive"
    queue "$archive"
  else
    rm -f "$tmp" "$tmp.aria2"
    warn "failed to download skin: $url"
  fi
}

foreach_manifest_line() {
  local file="$1" callback="$2" line
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '' | \#*) continue ;;
    esac
    "$callback" "$line"
  done <"$file"
}

foreach_manifest_line "$beatmaps_file" collect_beatmap
run_beatmaps
foreach_manifest_line "$skins_file" install_skin
