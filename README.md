# nix-osu-lazer

osu!lazer for NixOS, built from [gaavin/osu@raster-sync](https://github.com/gaavin/osu/tree/raster-sync), with declarative settings, beatmaps and skins.

> [!WARNING]
> This is a source build, so scores are not submitted and multiplayer is unavailable. The `master` branch packages the official AppImage instead.

`x86_64-linux` only.

## Features

- **Raster sync**: during gameplay, each frame is presented at a scanline chosen so the tear line falls in the blanking interval. VSync-off latency without a visible tear line.
- **Tearing on Wayland**: a patched SDL marks the window as a game and requests async flips through `tearing-control-v1`.
- **Low audio latency**: 128-sample BASS device period and a pipewire-alsa plugin that allows smaller ALSA periods, inside osu!'s sandbox only.
- **OpenTabletDriver**: `opentabletdriver.service` is stopped while osu! runs and restarted on exit.
- **Declarative config**: `game.ini` and `framework.ini` keys, beatmap sets and skins through a Home Manager module.

## Install

```bash
nix run github:gaavin/nix-osu-lazer/raster-sync
```

As a flake input:

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-osu-lazer.url = "github:gaavin/nix-osu-lazer/raster-sync";
    nix-osu-lazer.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, nix-osu-lazer, ... }: {
    nixosConfigurations.HOST = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        { nixpkgs.overlays = [ nix-osu-lazer.overlays.default ]; }
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.sharedModules = [ nix-osu-lazer.homeModules.default ];
          home-manager.users.USER.programs.nix-osu-lazer.enable = true;
        }
      ];
    };
  };
}
```

Requires `nixpkgs.config.allowUnfree = true` (BASS). Without Home Manager, add `pkgs.nix-osu-lazer` to `environment.systemPackages`.

## Raster sync

### Requirements

- OpenGL renderer
- Fullscreen or borderless
- Frame limiter other than VSync (Unlimited is best)
- Variable refresh rate off
- A compositor that allows `tearing-control-v1` async flips (KWin does by default)
- Read access to `/dev/dri/card*` (granted by logind at the active seat)

### Settings

Under **Graphics > Raster sync**. The note under the mode shows the display being followed, or why raster sync is idle.

| Setting | `game.ini` key | Default | |
|---|---|---|---|
| Raster sync | `RasterSyncMode` | `TearlineSync` | `Disabled`, `TearlineSync` (one present per refresh) or `FrameSlices` (several per refresh, with fixed tear lines between slices) |
| Frame slices per refresh | `RasterFrameSlices` | `4` | 2 to 16, `FrameSlices` mode only |
| Render headroom | `RasterRenderHeadroom` | `0.5` | Milliseconds kept spare on top of the longest recent frame |
| Show tear line indicator | `RasterShowTearline` | `false` | Strip on the right edge that alternates colour every present |

The tear line offset is automatic. osu! measures how long the compositor takes to flip each frame and steers the tear line into the blanking interval during a play. Finished plays are stored in `~/.local/share/osu/raster-sync-flips.json` and seed the next play. **Forget recorded flips** clears them.

### Checking the tear line

Turn on **Show tear line indicator**. Where a tear line crosses the strip, it shows both colours. With the tear line in blanking the strip flickers evenly with no split. The note under the checkbox shows the current steering target.

With several displays lit, pick the one osu! is on:

```bash
OSU_RASTER_DRM_DEVICE=/dev/dri/card1 OSU_RASTER_CRTC=<id> osu!
```

## Declarative config

```nix
programs.nix-osu-lazer = {
  enable = true;

  settings = {              # game.ini
    DimLevel = 1.0;
    ShowFirstRunSetup = false;
    RasterRenderHeadroom = 0.3;
  };

  frameworkSettings = {     # framework.ini
    FrameSync = "Unlimited";
    Renderer = "OpenGL";
    WindowMode = "Fullscreen";
  };

  beatmaps = [ 376552 2142914 ];   # beatmap set IDs
  skins = [ "https://example.com/MySkin.osk" ];
};
```

Settings are merged into `~/.local/share/osu` on `home-manager switch` and before every launch. Keys left out keep whatever osu! saved. osu! overwrites both files on exit, so changes made while it runs apply on the next launch. `Token` (the saved login) is refused.

`Skin` takes an ID. Built-in skins:

| Skin | ID |
|---|---|
| argon | `cffa69de-b3e3-4dee-8563-3c4f425c05d0` |
| argon pro | `9fc9cf5d-0f16-4c71-8256-98868321ac43` |
| triangles | `2991cfd8-2140-469a-bcb9-2ec23fbce4ad` |
| classic | `81f02cd3-eec6-4865-ac23-fae26a386187` |
| retro | `0555c76a-cc6b-4bb4-9548-df76ba72ef25` |

Imported skins get a new ID on every import, so select those in game.

Missing beatmap sets and skins are downloaded from mirrors on switch and at launch, then imported by osu! on the next plain `osu!` launch. Content deleted in game comes back two launches later.

```bash
osu! --apply-settings    # merge settings now
osu! --export-settings   # print settings that differ from a fresh install
osu! --sync-content      # download missing beatmaps and skins now
osu! --export-beatmaps   # print imported sets as a beatmaps list
```

## Package options

```nix
programs.nix-osu-lazer.package = pkgs.nix-osu-lazer.override { bassDevicePeriod = -256; };
```

| Argument | Default | |
|---|---|---|
| `osuSrc` | `null` | osu! source to build instead of the pinned commit, e.g. `builtins.fetchGit ~/Projects/osu` |
| `nativeWayland` | `true` | Set `SDL_VIDEODRIVER=wayland` |
| `bassDevicePeriod` | `-128` | BASS device period, in samples when negative. `null` for osu!'s default |
| `lowLatencyPipewireAlsa` | `true` | Use the patched pipewire-alsa plugin in the sandbox |
| `stopTabletDaemon` | `true` | Stop `opentabletdriver.service` while osu! runs |

`SDL_VIDEO_WAYLAND_GAME_PRESENTATION=0 osu!` disables the SDL patch for one launch.

## Verifying

Tearing hints:

```bash
tests=$(nix build --no-link --print-out-paths 'github:gaavin/nix-osu-lazer/raster-sync#default.sdl3-patched^installedTests')
WAYLAND_DEBUG=client "$tests/libexec/installed-tests/SDL3/testgl" 2>&1 \
  | grep -m2 -E 'set_content_type|set_presentation_hint'
```

Expect `set_content_type(3)` and `set_presentation_hint(1)`.

Raster sync log:

```bash
grep 'Raster sync' ~/.local/share/osu/logs/runtime.log
```

## Updating

1. Merge `ppy/osu` master into `raster-sync` in gaavin/osu and push.
2. Update `version`, `rev` and `hash` in `pkgs/nix-osu-lazer/default.nix`.
3. `nix build .#default.osu.fetch-deps && ./result pkgs/nix-osu-lazer/deps.json`
4. If the build reports a different bundled SDL commit, update `sdlRevision` and the SDL `src`, and rebase the SDL patch.
5. Refresh `factory-game.ini` and `factory-framework.ini` from a fresh data directory.

## Troubleshooting

| Issue | Fix |
|---|---|
| Tear line visible or jumping | Raise **Render headroom** and check the late count in the status note. Check the steering note under **Show tear line indicator**. |
| Steering note says flips are held for vblank | The compositor is not tearing. Use fullscreen and make sure nothing overlaps the game. |
| Status asks about variable refresh rate | Turn off Adaptive Sync for the display. |
| Status says a device cannot be opened | Log in at the seat or join the `video` group. |
| No tearing at all | Check OpenGL and Unlimited, then run the check under [Verifying](#verifying). |
| Audio crackles | `bassDevicePeriod = -256`, or `null`. |
| Tablet dead outside osu! | `systemctl --user start opentabletdriver.service` |
| Setting does not stick | osu! was running during the merge. Restart it. |
| Beatmaps not showing up | They import on a plain `osu!` launch, not when opening a file or link. |

## Credits

- [ppy/osu](https://github.com/ppy/osu)
- [Blur Busters](https://blurbusters.com): beam racing and lagless VSync
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL)
- [nixpkgs `osu-lazer`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/os/osu-lazer/package.nix)
- [gaavin/nix-osu-stable](https://github.com/gaavin/nix-osu-stable)
