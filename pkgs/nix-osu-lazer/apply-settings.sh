# Merge declarative osu!lazer settings into game.ini or framework.ini.
# Usage: nix-osu-lazer-apply-settings <managed.ini> <target.ini>
#
# A managed key replaces its line where it stands, or is appended when the file
# lacks it. Every other line is kept. Token, the saved login, is refused.

set -euo pipefail

managed="${1:?managed settings fragment}"
target="${2:?target ini path}"

[ -s "$managed" ] || exit 0

mkdir -p "$(dirname "$target")"
tmp="$(mktemp "$target.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

existing=/dev/null
if [ -f "$target" ]; then
  existing="$target"
fi

awk '
function trim(s) {
  gsub(/^[ \t\r]+|[ \t\r]+$/, "", s)
  return s
}
FNR == NR {
  eq = index($0, "=")
  if (eq < 1) next
  key = trim(substr($0, 1, eq - 1))
  if (key == "") next
  if (tolower(key) == "token") {
    print "nix-osu-lazer: refusing to manage Token, the saved login" > "/dev/stderr"
    failed = 1
    exit 1
  }
  if (!(key in value)) order[++n] = key
  value[key] = trim(substr($0, eq + 1))
  next
}
{
  eq = index($0, "=")
  key = eq > 0 ? trim(substr($0, 1, eq - 1)) : ""
  if (key != "" && key in value) {
    if (!(key in written)) print key " = " value[key]
    written[key] = 1
    next
  }
  print
}
END {
  if (failed) exit 1
  for (i = 1; i <= n; i++)
    if (!(order[i] in written)) print order[i] " = " value[order[i]]
}
' "$managed" "$existing" >"$tmp"

if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
  exit 0
fi

chmod 644 "$tmp"
mv -f "$tmp" "$target"
