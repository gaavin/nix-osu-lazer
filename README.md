<div align="center">

# nix-osu-lazer-tearing

**osu!lazer on NixOS, presenting as a tearing Wayland game surface.** Built on the official AppImage, so score submission and multiplayer keep working.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-informational?logo=NixOS)](https://nixos.org)
[![Flake](https://img.shields.io/badge/Flake-enabled-success)](https://nixos.wiki/wiki/Flakes)

<p>
  <img src="assets/osu-logo.svg" alt="osu!" width="96">
</p>

</div>

On Wayland, osu!lazer draws through SDL, and SDL never tells the compositor what its window is. With the frame limiter unlocked the swap interval is 0, but the compositor still holds every frame for the next vblank.

This flake takes the same AppImage as nixpkgs `osu-lazer-bin` and swaps only its bundled `libSDL3.so`. The replacement is built from the exact SDL commit osu! ships, plus [a patch](pkgs/osu-lazer-tearing/sdl3-wayland-game-presentation.patch) that:

- tags the window's `xdg_toplevel` surface as a game through `wp_content_type_v1`
- attaches `wp_tearing_control_v1` with an `async` hint while GL swaps at interval 0, and `vsync` otherwise

`osu.Game.dll` is left untouched. The server checks its MD5, so online play is unaffected.

The launcher also:

- sets `SDL_VIDEODRIVER=wayland`
- sets the BASS device period to 128 samples through osu!framework's `OSU_TEMP_TESTING_BASS_CONFIG_DEV_PERIOD` hook. Against a 128-sample PipeWire quantum, BASS's reported output latency drops from 15 ms to 5 ms
- stops the `opentabletdriver.service` user unit while osu! runs, and starts it again on exit. osu! reads the tablet itself, and a running daemon would hand it the pen a second time through its virtual tablet
- sets `OSU_EXTERNAL_UPDATE_PROVIDER=1`, so updates come from nixpkgs

> [!NOTE]
> `x86_64-linux` only. The tearing hint is sent for osu!'s OpenGL renderer with the frame limiter on Unlimited; on Vulkan, Mesa's WSI attaches its own. The compositor has to implement and allow `tearing-control-v1` (KWin allows it by default).

## Quick Start

```bash
nix run github:gaavin/nix-osu-lazer-tearing
```

## Install

### 1. Add the overlay

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    nix-osu-lazer-tearing.url = "github:gaavin/nix-osu-lazer-tearing";
    nix-osu-lazer-tearing.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, nix-osu-lazer-tearing, ... }:
    {
      nixosConfigurations.YOUR_CONFIGURATION = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          { nixpkgs.overlays = [ nix-osu-lazer-tearing.overlays.default ]; }
        ];
      };
    };
}
```

The overlay builds against your own nixpkgs, so the AppImage version follows your `osu-lazer-bin`. Like `osu-lazer-bin`, it needs `nixpkgs.config.allowUnfree = true` (BASS).

### 2. Install the package

```nix
home.packages = [ pkgs.osu-lazer-tearing ];
```

or `environment.systemPackages`. Either way it installs `osu!` and a desktop entry.

## Options

Pass these with `.override`:

```nix
(pkgs.osu-lazer-tearing.override { bassDevicePeriod = -256; })
```

| Argument | Default | Effect |
|----------|---------|--------|
| `nativeWayland` | `true` | Sets `SDL_VIDEODRIVER=wayland`. Without it SDL may pick XWayland, where none of this applies. |
| `bassDevicePeriod` | `-128` | BASS device update period, in samples when negative. `null` keeps osu!'s default. Set with `--set-default`, so exporting the variable overrides it for one launch. |
| `stopTabletDaemon` | `true` | Stops `opentabletdriver.service` while osu! runs. Turn it off if osu!'s own tablet support is disabled. |

`SDL_VIDEO_WAYLAND_GAME_PRESENTATION=0 osu!` restores stock SDL behaviour without a rebuild.

## Verifying

The patched SDL's test programs show whether the hints go out:

```bash
tests=$(nix build --no-link --print-out-paths 'github:gaavin/nix-osu-lazer-tearing#default.sdl3-patched^installedTests')
WAYLAND_DEBUG=client "$tests/libexec/installed-tests/SDL3/testgl" 2>&1 \
  | grep -m2 -E 'set_content_type|set_presentation_hint'
```

Expect `set_content_type(3)` (game) and `set_presentation_hint(1)` (async).

## Updating

When nixpkgs moves `osu-lazer-bin` to a release that bundles a different SDL commit, the build stops and prints the commit the new AppImage carries. Point `sdlRevision` and the SDL `src` in `pkgs/osu-lazer-tearing/default.nix` at it, and rebase the patch if it no longer applies.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Audio crackles | Raise the period: `bassDevicePeriod = -256`, or `null` for osu!'s default. |
| No tearing | Check that osu! uses OpenGL with the frame limiter on Unlimited, then run the check under [Verifying](#verifying). |
| Tablet dead outside osu! | The launcher restarts the daemon when osu! exits. If the launcher itself was killed with SIGKILL, run `systemctl --user start opentabletdriver.service`. |

## Credits

- [ppy/osu](https://github.com/ppy/osu): osu!lazer
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL)
- [NixOS/nixpkgs `osu-lazer-bin`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/os/osu-lazer-bin/package.nix): the AppImage packaging this builds on
