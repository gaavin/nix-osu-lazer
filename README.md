<div align="center">

# nix-osu-lazer

**osu!lazer on NixOS, with declarative settings, beatmaps and skins, presenting as a tearing Wayland game surface.** Built on the official AppImage, so score submission and multiplayer keep working.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-informational?logo=NixOS)](https://nixos.org)
[![Flake](https://img.shields.io/badge/Flake-enabled-success)](https://nixos.wiki/wiki/Flakes)

<p>
  <img src="assets/osu-logo.svg" alt="osu!" width="96">
</p>

</div>

On Wayland, osu!lazer draws through SDL, and SDL never tells the compositor what its window is. With the frame limiter unlocked the swap interval is 0, but the compositor still holds every frame for the next vblank.

This flake takes the same AppImage as nixpkgs `osu-lazer-bin` and swaps only its bundled `libSDL3.so`. The replacement is built from the exact SDL commit osu! ships, plus [a patch](pkgs/nix-osu-lazer/sdl3-wayland-game-presentation.patch) that:

- tags the window's `xdg_toplevel` surface as a game through `wp_content_type_v1`
- attaches `wp_tearing_control_v1` with an `async` hint while GL swaps at interval 0, and `vsync` otherwise

`osu.Game.dll` is left untouched. The server checks its MD5, so online play is unaffected.

The launcher also:

- sets `SDL_VIDEODRIVER=wayland`
- sets the BASS device period to 128 samples through osu!framework's `OSU_TEMP_TESTING_BASS_CONFIG_DEV_PERIOD` hook. Against a 128-sample PipeWire quantum, BASS's reported output latency drops from 15 ms to 5 ms
- loads a [patched](pkgs/nix-osu-lazer/pipewire-alsa-low-latency.patch) pipewire-alsa PCM plugin, which accepts ALSA periods down to 8 frames and 64 bytes instead of 64 frames and 128 bytes. It goes into the sandbox's `/etc/asound.conf`, so the rest of the system keeps the stock plugin
- stops the `opentabletdriver.service` user unit while osu! runs, and starts it again on exit. osu! reads the tablet itself, and a running daemon would hand it the pen a second time through its virtual tablet
- sets `OSU_EXTERNAL_UPDATE_PROVIDER=1`, so updates come from nixpkgs
- merges declarative settings and imports declarative beatmaps and skins, when the [Home Manager module](#declarative-settings-beatmaps-and-skins) sets them

> [!NOTE]
> `x86_64-linux` only. The tearing hint is sent for osu!'s OpenGL renderer with the frame limiter on Unlimited; on Vulkan, Mesa's WSI attaches its own. The compositor has to implement and allow `tearing-control-v1` (KWin allows it by default).

## Quick Start

```bash
nix run github:gaavin/nix-osu-lazer
```

## Install

### 1. Add the flake

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-osu-lazer.url = "github:gaavin/nix-osu-lazer";
    nix-osu-lazer.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, nix-osu-lazer, ... }:
    {
      nixosConfigurations.YOUR_CONFIGURATION = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          { nixpkgs.overlays = [ nix-osu-lazer.overlays.default ]; }
          home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              sharedModules = [ nix-osu-lazer.homeModules.nix-osu-lazer ];
              users.YOUR_USERNAME = import ./home.nix;
            };
          }
        ];
      };
    };
}
```

The package builds against your own nixpkgs, so the AppImage version follows your `osu-lazer-bin`. Like `osu-lazer-bin`, it needs `nixpkgs.config.allowUnfree = true` (BASS). The overlay is optional for the module, which builds the package from your `pkgs` either way.

### 2. Enable it

```nix
programs.nix-osu-lazer.enable = true;
```

This installs `osu!` and a desktop entry. Without Home Manager, install `pkgs.nix-osu-lazer` through `environment.systemPackages` instead.

## Declarative settings, beatmaps and skins

```nix
programs.nix-osu-lazer = {
  enable = true;

  # game.ini
  settings = {
    BeatmapSkins = false;
    BeatmapColours = false;
    DimLevel = 1.0;
    ShowFirstRunSetup = false;
  };

  # framework.ini
  frameworkSettings = {
    FrameSync = "Unlimited";
    Renderer = "OpenGL";
    VolumeUniversal = 0.83;
  };

  beatmaps = [
    376552
    2142914
  ];

  skins = [ "https://circle-people.com/wp-content/Skins/Cookiezi/Cookiezi%2004.osk" ];
};
```

### Settings

Keys match osu!'s own `game.ini` and `framework.ini`, which live in `~/.local/share/osu` (`game.ini` follows a custom data location set in game). They are merged on `home-manager switch` and before every launch. Keys you leave out keep whatever osu! saved, including your login.

osu! writes both files back when it exits, so nothing is merged while it runs. The launch after picks the settings up again.

`Skin` takes a skin's ID rather than its name. The built-in skins have fixed IDs:

| Skin | ID |
|------|----|
| argon | `cffa69de-b3e3-4dee-8563-3c4f425c05d0` |
| argon pro | `9fc9cf5d-0f16-4c71-8256-98868321ac43` |
| triangles | `2991cfd8-2140-469a-bcb9-2ec23fbce4ad` |
| classic | `81f02cd3-eec6-4865-ac23-fae26a386187` |
| retro | `0555c76a-cc6b-4bb4-9548-df76ba72ef25` |

An imported skin gets a new ID each time it is imported, so pick it in game. Key bindings are kept in osu!'s database rather than an ini file and cannot be set here. The module refuses `Token`, the saved login.

```bash
osu! --apply-settings    # merge now
osu! --export-settings   # print what differs from a fresh install, ready to paste
```

`--export-settings` compares against `game.ini` and `framework.ini` captured from a fresh install of the packaged release, and leaves out the login and values osu! keeps for its own bookkeeping.

### Beatmaps and skins

osu!lazer keeps beatmaps and skins in its database, which only the game itself can write. Missing beatmap sets and skins are downloaded on `home-manager switch` and at launch. A plain `osu!` launch then hands osu! the archives, and it imports them and deletes each one.

Beatmaps come from [catboy.best](https://catboy.best), [osu.direct](https://osu.direct), [nerinyan](https://nerinyan.moe), [beatconnect](https://beatconnect.io) and [sayobot](https://osu.sayobot.cn). The mirrors are probed first, then every missing set downloads in one parallel [aria2](https://aria2.github.io/) run spread across the mirrors that answered, preferring no-video downloads. A set that fails retries on the next mirror. Failed downloads are warned about and skipped, so activation still succeeds.

osu! stores every file under `files/` by its SHA-256. When an archive is downloaded, the hashes of its files are recorded in `~/.local/state/nix-osu-lazer`. A set or skin counts as imported while all of them are in `files/`. After the data directory is wiped, everything comes back on the next launch. Something deleted in game comes back two launches later, because osu! only removes a deleted item's files while it starts, after the launcher has checked. The first switch downloads everything once, even sets osu! already has; osu! recognises those and skips them.

```bash
osu! --sync-content      # download anything missing now; it is imported on the next launch
osu! --export-beatmaps   # print the imported sets as a beatmaps list, ready to paste
```

`--export-beatmaps` reads the set ID from each `.osu` file in `files/`, since the database is closed to anything but osu!. Files older than format v10 carry no set ID; those are found through the recorded hashes when this package downloaded them, and otherwise left out with a warning. A set deleted in game keeps its files until osu! next starts, so export after a launch.

## Package options

Pass these with `.override`, or set the module's `package` to the result:

```nix
programs.nix-osu-lazer.package = pkgs.nix-osu-lazer.override { bassDevicePeriod = -256; };
```

| Argument | Default | Effect |
|----------|---------|--------|
| `nativeWayland` | `true` | Sets `SDL_VIDEODRIVER=wayland`. Without it SDL may pick XWayland, where none of this applies. |
| `bassDevicePeriod` | `-128` | BASS device update period, in samples when negative. `null` keeps osu!'s default. Set with `--set-default`, so exporting the variable overrides it for one launch. |
| `lowLatencyPipewireAlsa` | `true` | Loads the patched pipewire-alsa plugin inside osu!'s sandbox. Smaller periods only help if PipeWire's own quantum goes that low too (`default.clock.min-quantum`). |
| `stopTabletDaemon` | `true` | Stops `opentabletdriver.service` while osu! runs. Turn it off if osu!'s own tablet support is disabled. |

`SDL_VIDEO_WAYLAND_GAME_PRESENTATION=0 osu!` restores stock SDL behaviour without a rebuild.

## Verifying

The patched SDL's test programs show whether the hints go out:

```bash
tests=$(nix build --no-link --print-out-paths 'github:gaavin/nix-osu-lazer#default.sdl3-patched^installedTests')
WAYLAND_DEBUG=client "$tests/libexec/installed-tests/SDL3/testgl" 2>&1 \
  | grep -m2 -E 'set_content_type|set_presentation_hint'
```

Expect `set_content_type(3)` (game) and `set_presentation_hint(1)` (async).

## Updating

When nixpkgs moves `osu-lazer-bin` to a release that bundles a different SDL commit, the build stops and prints the commit the new AppImage carries. Point `sdlRevision` and the SDL `src` in `pkgs/nix-osu-lazer/default.nix` at it, and rebase the patch if it no longer applies.

A new release can also add settings or change their defaults. Refresh `factory-game.ini` and `factory-framework.ini` from a fresh data directory so `--export-settings` stays accurate.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Audio crackles | Raise the period: `bassDevicePeriod = -256`, or `null` for osu!'s default. |
| No tearing | Check that osu! uses OpenGL with the frame limiter on Unlimited, then run the check under [Verifying](#verifying). |
| Tablet dead outside osu! | The launcher restarts the daemon when osu! exits. If the launcher itself was killed with SIGKILL, run `systemctl --user start opentabletdriver.service`. |
| A setting does not stick | osu! was running when it was merged. Close osu! and launch it again. |
| Beatmaps not showing up | They are imported on a plain `osu!` launch, not when osu! is opened with a file or link. |

## Credits

- [ppy/osu](https://github.com/ppy/osu): osu!lazer
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL)
- vestaia from thePooN's Discord server: pipewire-alsa patches
- [NixOS/nixpkgs `osu-lazer-bin`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/os/osu-lazer-bin/package.nix): the AppImage packaging this builds on
- [gaavin/nix-osu-stable](https://github.com/gaavin/nix-osu-stable): the beatmap mirror downloader and settings merge this adapts
