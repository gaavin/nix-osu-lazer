# Launches osu!lazer. A plain launch first merges the declarative settings and
# hands osu! the declarative beatmap sets and skins it has not imported yet.

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/osu"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/nix-osu-lazer"

info() {
  printf 'nix-osu-lazer: %s\n' "$*" >&2
}

# A custom data location in storage.ini moves game.ini and files/ there, while
# framework.ini and storage.ini itself stay behind.
game_dir() {
  local custom=""
  if [ -r "$data_dir/storage.ini" ]; then
    custom="$(sed -nE -e 's/[[:space:]]+$//' -e 's/^[[:space:]]*FullPath[[:space:]]*=[[:space:]]*//p' \
      "$data_dir/storage.ini" | tail -n 1)"
  fi
  printf '%s\n' "${custom:-$data_dir}"
}

# osu! holds a named pipe as its single-instance lock, listening only while it
# runs.
osu_running() {
  [[ "$(ss -Hxl 2>/dev/null)" == *CoreFxPipe_osu-framework-osu-lazer* ]]
}

apply_settings() {
  [ -n "$game_settings$framework_settings" ] || return 0
  if osu_running; then
    info "osu! is running and saves its settings when it exits; settings not merged"
    return 0
  fi
  if [ -n "$framework_settings" ]; then
    "$apply_settings_bin" "$framework_settings" "$data_dir/framework.ini"
  fi
  if [ -n "$game_settings" ]; then
    "$apply_settings_bin" "$game_settings" "$(game_dir)/game.ini"
  fi
}

# Prints the archives osu! still has to import.
sync_content() {
  [ -n "$beatmaps$skins" ] || return 0
  "$sync_content_bin" "${beatmaps:-/dev/null}" "${skins:-/dev/null}" "$(game_dir)" "$state_dir"
}

export_settings() {
  local dir
  dir="$(game_dir)"
  printf 'settings = {\n'
  "$export_settings_bin" "$dir/game.ini" "$factory_game"
  printf '};\n\nframeworkSettings = {\n'
  "$export_settings_bin" "$data_dir/framework.ini" "$factory_framework"
  printf '};\n'
}

# osu! reads the tablet over hidraw through its bundled OpenTabletDriver. A
# running otd-daemon reads the same tablet and replays it through its virtual
# tablet, so the pen would also reach osu! through the compositor: later, and
# mapped by the daemon's area instead of osu!'s.
unit=opentabletdriver.service
stopped=

restart_daemon() {
  if [ -n "$stopped" ]; then
    systemctl --user --no-block start "$unit" || true
  fi
}

launch() {
  local running=""
  local -a imports=()

  if osu_running; then
    running=1
  fi

  apply_settings

  # osu! imports its arguments as files only when the first one has a dot in
  # it, and follows an osu:// link only when it is the sole argument, so the
  # archives are added to a plain launch alone.
  if [ "$#" -eq 0 ]; then
    mapfile -t imports < <(sync_content)
    if [ "${#imports[@]}" -gt 0 ]; then
      info "importing ${#imports[@]} beatmap set(s) and skin(s)"
    fi
  fi

  # A second launch only hands its arguments to the running instance. It finds
  # the daemon already stopped, so restarting it is left to the first.
  if [ -z "$stop_tablet_daemon" ] || [ -n "$running" ]; then
    exec "$osu" "$@" "${imports[@]}"
  fi

  trap restart_daemon EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if systemctl --user --quiet is-active "$unit" 2>/dev/null; then
    systemctl --user stop "$unit" && stopped=1
  fi

  "$osu" "$@" "${imports[@]}"
}

case "${1:-}" in
  --apply-settings)
    apply_settings
    ;;
  --sync-content)
    mapfile -t pending < <(sync_content)
    info "${#pending[@]} beatmap set(s) and skin(s) waiting to be imported on the next launch"
    ;;
  --export-settings)
    export_settings
    ;;
  *)
    launch "$@"
    ;;
esac
