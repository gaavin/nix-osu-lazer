# Print the beatmap sets osu!lazer has imported, as the module's beatmaps list.
# Usage: nix-osu-lazer-export-beatmaps <game-dir> <state-dir>
#
# osu! keeps its beatmap sets in the realm database, which nothing outside the
# game can read, but it stores every .osu file as-is under files/, named by its
# SHA-256. The set ID is read from each .osu file's [Metadata] section. Files
# older than format v10 have none, so their ID is looked up in the hashes
# recorded when the set was downloaded, and any other such set is left out.
#
# A set deleted in game keeps its files until osu! next starts, so export after
# a launch.

set -euo pipefail

game_dir="${1:?osu! data directory}"
state_dir="${2:?state directory}"

files_dir="$game_dir/files"
hashes_dir="$state_dir/hashes/beatmaps"

if [ ! -d "$files_dir" ]; then
  printf 'nix-osu-lazer: %s does not exist yet (launch osu! once)\n' "$files_dir" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# <hash> <set id> for every .osu file of a set this package downloaded.
known="$work/known"
: >"$known"
if [ -d "$hashes_dir" ]; then
  find "$hashes_dir" -maxdepth 1 -type f -name '[0-9]*' \
    -exec gawk '{ n = split(FILENAME, p, "/"); print $1, p[n] }' {} + >"$known"
fi

# One gawk reads every path from a list, since a split across several runs
# would print several lists. Stored file names are hashes, so one per line is
# safe.
paths="$work/paths"
find "$files_dir" -type f -size +0 >"$paths"

# Binary files are dropped at their first line. An .osu file is read only up
# to the end of [Metadata], which comes before its events and hit objects.
LC_ALL=C gawk -v known="$known" -v paths="$paths" '
function record() {
  if (id == "") {
    n = split(FILENAME, p, "/")
    if (p[n] in by_hash) id = by_hash[p[n]]
    else unknown[artist " - " title] = 1
  }
  if (id != "" && id + 0 > 0) ids[id + 0] = 1
  done = 1
}
BEGIN {
  while ((getline line < known) > 0) {
    split(line, f, " ")
    by_hash[f[1]] = f[2]
  }
  close(known)
  while ((getline line < paths) > 0) ARGV[ARGC++] = line
  close(paths)
  # With no files gawk would read stdin.
  if (ARGC == 1) ARGV[ARGC++] = "/dev/null"
}
BEGINFILE {
  id = ""
  artist = "?"
  title = "?"
  osu = 0
  done = 0
}
FNR == 1 {
  sub(/^\xef\xbb\xbf/, "")
  if ($0 !~ /^[ \t]*osu file format v[0-9]+/) nextfile
  osu = 1
  next
}
/^[ \t]*\[.*\][ \t\r]*$/ {
  if (section == "Metadata") {
    record()
    nextfile
  }
  section = $0
  gsub(/^[ \t]*\[|\][ \t\r]*$/, "", section)
  next
}
section == "Metadata" && /^[ \t]*(Artist|Title)[ \t]*:/ {
  v = $0
  sub(/^[^:]*:[ \t]*/, "", v)
  sub(/[ \t\r]+$/, "", v)
  if ($0 ~ /^[ \t]*Artist/) artist = v
  else title = v
  next
}
section == "Metadata" && /^[ \t]*BeatmapSetID[ \t]*:/ {
  v = $0
  sub(/^[^:]*:[ \t]*/, "", v)
  sub(/[ \t\r]+$/, "", v)
  if (v ~ /^-?[0-9]+$/) id = v
  record()
  nextfile
}
ENDFILE {
  if (osu && !done) record()
  section = ""
}
END {
  for (name in unknown)
    printf "nix-osu-lazer: left out %s: its .osu files predate beatmap set IDs\n", name > "/dev/stderr"
  count = asorti(ids, sorted, "@ind_num_asc")
  if (count == 0) {
    print "beatmaps = [ ];"
  } else if (count == 1) {
    printf "beatmaps = [ %s ];\n", sorted[1]
  } else {
    print "beatmaps = ["
    for (i = 1; i <= count; i++) printf "  %s\n", sorted[i]
    print "];"
  }
}
'
