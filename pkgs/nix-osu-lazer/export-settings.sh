# Print the settings in an osu!lazer ini file that differ from a fresh install,
# as Nix attributes.
# Usage: nix-osu-lazer-export-settings <game.ini|framework.ini> <factory.ini>
#
# The login (Token, Username) and values osu! keeps for its own bookkeeping
# (Version, metadata cursors, supporter state) are left out.

set -euo pipefail

current="${1:?ini file}"
factory="${2:?factory ini file}"

if [ ! -f "$current" ]; then
  printf 'nix-osu-lazer: %s does not exist yet (launch osu! once)\n' "$current" >&2
  exit 1
fi

awk '
function trim(s) {
  gsub(/^[ \t\r]+|[ \t\r]+$/, "", s)
  return s
}
# osu! writes 1.0 where Nix writes 1.
function norm(v) {
  v = trim(v)
  if (v ~ /^-?[0-9]+\.[0-9]+$/) {
    sub(/0+$/, "", v)
    sub(/\.$/, "", v)
  }
  return v
}
function skip(k) {
  return k == "Token" || k == "Username" || k == "Version" \
    || k == "LastProcessedMetadataId" || k == "LastOnlineTagsPopulation" || k == "WasSupporter"
}
function nix_string(s,    out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\" || c == "\"" || (c == "$" && substr(s, i + 1, 1) == "{")) out = out "\\" c
    else out = out c
  }
  return "\"" out "\""
}
function nix_value(v) {
  if (v == "True") return "true"
  if (v == "False") return "false"
  if (v ~ /^-?[0-9]+(\.[0-9]+)?$/) return v
  return nix_string(v)
}
{
  eq = index($0, "=")
  if (eq < 1) next
  key = trim(substr($0, 1, eq - 1))
  if (key == "" || skip(key)) next
  val = norm(substr($0, eq + 1))
  if (FNR == NR) {
    defaults[key] = val
    next
  }
  if ((key in defaults) && defaults[key] == val) next
  printf "  %s = %s;\n", key, nix_value(val)
}
' "$factory" "$current"
