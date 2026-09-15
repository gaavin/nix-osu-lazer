<div align="center">

# nix-osu-lazer

**osu!lazer on NixOS with raster sync: each frame is presented in step with the display's scanout, so the tear line hides in the blanking interval at VSync-off latency.** With declarative settings, beatmaps and skins, presenting as a tearing Wayland game surface.

[![NixOS](https://img.shields.io/badge/NixOS-unstable-informational?logo=NixOS)](https://nixos.org)
[![Flake](https://img.shields.io/badge/Flake-enabled-success)](https://nixos.wiki/wiki/Flakes)

<p>
  <img src="assets/osu-logo.svg" alt="osu!" width="96">
</p>

</div>

> [!WARNING]
> This branch builds osu! from source, from the `raster-sync` branch of [gaavin/osu](https://github.com/gaavin/osu/tree/raster-sync). The server only accepts scores from official builds, so scores are not submitted and multiplayer is unavailable. The `master` branch packages the official AppImage instead.

## Raster sync

With VSync off, a new frame takes over from whichever scanline the display is scanning out when it is flipped, and the boundary shows as a tear line. VSync avoids it by holding every frame until the blanking interval, which costs up to a refresh of latency. Raster sync keeps VSync off and times each present instead, following Blur Busters' [beam racing](https://blurbusters.com/blur-busters-lagless-raster-follower-algorithm-for-emulator-developers/) and [lagless VSync](https://blurbusters.com/rtss-scanline-sync-howto/) techniques:

1. A thread waits on the display's vblanks with `DRM_IOCTL_WAIT_VBLANK` on `/dev/dri/card*`. The compositor holds DRM master, but reading a CRTC's mode and waiting on vblank are open to any client. A least-squares fit over the last 256 kernel timestamps gives the refresh period and phase, and the mode gives the total and visible line counts.
2. The draw thread picks the next present time whose scanline sits in the middle of the blanking interval, moved by the tear line offset. It sleeps until that time, minus the longest frame of the last 64, minus the render headroom.
3. It draws the newest scene from the update thread, waits for the GPU with `glFinish`, sleeps to within 1 ms of the target, and spins the rest of the way before swapping.

KWin flips a tearing fullscreen surface as soon as it is committed. Aimed at the blanking interval, the tear line never reaches the visible screen, and the top of the screen shows a frame drawn a render time before it was scanned out.

**Frame slices** mode presents 2 to 16 frames per refresh at evenly spaced scanlines instead. Each band of the screen shows a frame drawn just before scanout reached it, at the cost of stationary tear lines between the bands.

Raster sync only paces frames during gameplay, including pauses and breaks within a map. Menus, song select, results and replays draw as they would without it, since waiting on scanout only made them lag. The vblank clock keeps running meanwhile, so pacing starts straight away when a map does.

During gameplay with the frame limiter on Unlimited, osu!'s 1000 Hz cap on update and draw frames is lifted, so the scene drawn is never older than one update frame. The cap comes back in menus.

On a 2560x1440 display at 144 Hz, with 1543 total lines, 103 of them blanking and 4.5 µs per line, the fitted clock predicted the next kernel vblank to within 0.7 µs. The timed wait landed within 4 µs of its target at the 99th percentile, under one scanline. This was measured with the game's timing code, outside the game.

### Requirements

- The OpenGL renderer, in fullscreen or borderless
- A frame limiter other than VSync. Unlimited is best
- A compositor that flips `tearing-control-v1` surfaces asynchronously. KWin allows it by default, and this package's SDL sends the hint
- Variable refresh rate off. Raster sync stops if vblanks stop matching the mode's refresh rate
- Read access to `/dev/dri/card*`, which logind grants the user at the active seat

### Settings

They are under **Graphics > Raster sync**. The note under the mode shows which display is followed, or why raster sync is idle, along with presents per second, the longest render, late presents and timing error.

| Setting | `game.ini` key | Default | Effect |
|---------|----------------|---------|--------|
| Raster sync | `RasterSyncMode` | `TearlineSync` | `Disabled`, `TearlineSync` (one present per refresh, tear line in blanking) or `FrameSlices` |
| Frame slices per refresh | `RasterFrameSlices` | `4` | Presents per refresh in `FrameSlices` mode, 2 to 16 |
| Find tear line offset from previous plays | `RasterAutoTearlineOffset` | `true` | Aims the tear line using compositor flip times recorded during plays |
| Tear line offset | `RasterTearlineOffset` | `0` | Scanlines to move the tear line by, on top of the found offset when that is on. Negative moves it up |
| Render headroom | `RasterRenderHeadroom` | `0.5` | Milliseconds kept spare on top of the longest recent frame |
| Show tear line indicator | `RasterShowTearline` | `false` | A strip on the right edge that changes colour with every present |

These can be set declaratively like any other key under `settings`. **Use the found offset as the manual offset** copies the found offset into the manual one and turns finding off. **Forget recorded flips** starts the recording over.

### Finding the offset from previous plays

A present leaves osu! on time, but the compositor takes a moment to flip it, and scanout moves on in the meantime. The tear line lands that much further down the screen.

During plays, osu! times that delay. After every third timed swap, it polls the CRTC until the framebuffer on its primary plane changes, which happens once the kernel accepts the compositor's flip. Reading the CRTC is open to any client and takes about 2 µs. Each play's swap-to-flip times go into a histogram of 10 µs bins, and the last 20 plays at each display mode are kept in `~/.local/share/osu/raster-sync-flips.json`.

Every recorded play weighs the same. osu! finds the span of flip times, as long as the blanking interval lasts, that holds the most flips. It then moves the tear line up by the scanlines scanout covers in the average flip time inside that span. The setting's note shows the found offset, the median flip time, and the share of flips that land inside the blanking interval at that offset.

A play counts once it has 200 timed flips. It is left out if its median flip time is over 3 ms, which means the compositor was holding frames for vblank instead of tearing, for example with a notification on screen. It is also left out if its middle half of flip times spreads over more than 1.5 ms.

The probe sees the kernel accept a flip slightly before the display driver programs it. If a tear line still shows at the top of the screen, move it up with the manual offset, which is added to the found one.

On the desktop, with KWin compositing at vblank, the probe put KWin's flips 5.45 ms after each vblank, 56 µs between the 10th and 90th percentiles, and timed 300 of 300 swaps.

### Calibrating the tear line by eye

The indicator shows where tear lines actually land, which also checks the found offset.

1. Turn on **Show tear line indicator**. The strip on the right edge alternates magenta and green, and wherever a tear line crosses it, it splits into both colours. The white ticks mark quarters of the screen.
2. Lower **Tear line offset** until the split appears at the bottom of the screen, and note the value. Raise it until the split appears at the top, and note that.
3. Set the offset halfway between the two, and turn the indicator off.

If the split jumps around instead of holding still, frames are finishing late. Raise **Render headroom**, or check the late count in the status.

The blanking interval is short, 0.46 ms in the example above. A custom mode with a longer vertical total at the same refresh rate (Quick Frame Transport) gives the tear line more room.

`OSU_RASTER_DRM_DEVICE=/dev/dri/card1` and `OSU_RASTER_CRTC=<id>` choose the display when several are lit and osu!'s cannot be told apart by its mode.

## Also in the package

osu! draws through SDL, and on Wayland SDL never tells the compositor what its window is. With the frame limiter unlocked the swap interval is 0, but the compositor still holds every frame for the next vblank. The package swaps the build's bundled `libSDL3.so` for the same SDL commit, plus [a patch](pkgs/nix-osu-lazer/sdl3-wayland-game-presentation.patch) that:

- tags the window's `xdg_toplevel` surface as a game through `wp_content_type_v1`
- attaches `wp_tearing_control_v1` with an `async` hint while GL swaps at interval 0, and `vsync` otherwise

The launcher also:

- sets `SDL_VIDEODRIVER=wayland`
- sets the BASS device period to 128 samples through osu!framework's `OSU_TEMP_TESTING_BASS_CONFIG_DEV_PERIOD` hook. Against a 128-sample PipeWire quantum, BASS's reported output latency drops from 15 ms to 5 ms
- loads a [patched](pkgs/nix-osu-lazer/pipewire-alsa-low-latency.patch) pipewire-alsa PCM plugin, which accepts ALSA periods down to 8 frames and 64 bytes instead of 64 frames and 128 bytes. It goes into the sandbox's `/etc/asound.conf`, so the rest of the system keeps the stock plugin
- stops the `opentabletdriver.service` user unit while osu! runs, and starts it again on exit. osu! reads the tablet itself, and a running daemon would hand it the pen a second time through its virtual tablet
- sets `OSU_EXTERNAL_UPDATE_PROVIDER=1`, so osu! does not update itself
- merges declarative settings and imports declarative beatmaps and skins, when the [Home Manager module](#declarative-settings-beatmaps-and-skins) sets them

> [!NOTE]
> `x86_64-linux` only. The compositor has to implement and allow `tearing-control-v1`.

## Quick Start

```bash
nix run github:gaavin/nix-osu-lazer/raster-sync
```

## Install

### 1. Add the flake

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nix-osu-lazer.url = "github:gaavin/nix-osu-lazer/raster-sync";
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

The package builds with your own nixpkgs' .NET 8 SDK, SDL and PipeWire. The osu! version is pinned by the branch. Like `osu-lazer`, it needs `nixpkgs.config.allowUnfree = true` (BASS). The overlay is optional for the module, which builds the package from your `pkgs` either way.

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
    RasterTearlineOffset = -40;
  };

  # framework.ini
  frameworkSettings = {
    FrameSync = "Unlimited";
    Renderer = "OpenGL";
    WindowMode = "Fullscreen";
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

`--export-settings` compares against `game.ini` and `framework.ini` captured from a fresh install of the packaged release, with the raster sync defaults added. It leaves out the login and values osu! keeps for its own bookkeeping.

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
| `osuSrc` | `null` | osu! source to build in place of the pinned `raster-sync` branch, such as `builtins.fetchGit ~/Projects/osu`. |
| `nativeWayland` | `true` | Sets `SDL_VIDEODRIVER=wayland`. Without it SDL may pick XWayland, where none of this applies. |
| `bassDevicePeriod` | `-128` | BASS device update period, in samples when negative. `null` keeps osu!'s default. Set with `--set-default`, so exporting the variable overrides it for one launch. |
| `lowLatencyPipewireAlsa` | `true` | Loads the patched pipewire-alsa plugin inside osu!'s sandbox. Smaller periods only help if PipeWire's own quantum goes that low too (`default.clock.min-quantum`). |
| `stopTabletDaemon` | `true` | Stops `opentabletdriver.service` while osu! runs. Turn it off if osu!'s own tablet support is disabled. |

`SDL_VIDEO_WAYLAND_GAME_PRESENTATION=0 osu!` restores stock SDL behaviour without a rebuild.

## Verifying

The patched SDL's test programs show whether the tearing hints go out:

```bash
tests=$(nix build --no-link --print-out-paths 'github:gaavin/nix-osu-lazer/raster-sync#default.sdl3-patched^installedTests')
WAYLAND_DEBUG=client "$tests/libexec/installed-tests/SDL3/testgl" 2>&1 \
  | grep -m2 -E 'set_content_type|set_presentation_hint'
```

Expect `set_content_type(3)` (game) and `set_presentation_hint(1)` (async).

Raster sync logs the display it follows to `~/.local/share/osu/logs/runtime.log`:

```bash
grep 'Raster sync' ~/.local/share/osu/logs/runtime.log
```

## Updating

The osu! build is the `raster-sync` branch of gaavin/osu, which sits on a `-lazer` release tag. To move to a newer release:

1. Rebase the branch onto the new tag, and push it.
2. Set `version` and the source `hash` in `pkgs/nix-osu-lazer/default.nix`.
3. Regenerate the NuGet lockfile: `nix build .#default.osu.fetch-deps && ./result pkgs/nix-osu-lazer/deps.json`.

If the new release's ppy.SDL3-CS bundles a different SDL commit, the build stops and prints it. Point `sdlRevision` and the SDL `src` at that commit, and rebase the patch if it no longer applies.

A new release can also add settings or change their defaults. Refresh `factory-game.ini` and `factory-framework.ini` from a fresh data directory so `--export-settings` stays accurate.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tear line visible near the top or bottom | Play a few maps with [offset finding](#finding-the-offset-from-previous-plays) on, then trim what is left with the manual offset, [by eye](#calibrating-the-tear-line-by-eye). |
| Offset finder leaves plays out | Its note gives the reason. Flips held for vblank mean the compositor was not tearing: check fullscreen, and that nothing overlapped the game. |
| Tear line jumps around | Frames are finishing late. Raise **Render headroom**, and check the late count in the raster sync status. |
| Raster sync status asks whether variable refresh rate is on | Turn Adaptive Sync off for the display. |
| Raster sync status says a device cannot be opened | The user needs access to `/dev/dri/card*`: log in at the seat, or join the `video` group. |
| Raster sync status says it needs fullscreen, OpenGL or another frame limiter | Change that setting. |
| No tearing at all | Check that osu! uses OpenGL with the frame limiter on Unlimited, then run the check under [Verifying](#verifying). |
| Audio crackles | Raise the period: `bassDevicePeriod = -256`, or `null` for osu!'s default. |
| Tablet dead outside osu! | The launcher restarts the daemon when osu! exits. If the launcher itself was killed with SIGKILL, run `systemctl --user start opentabletdriver.service`. |
| A setting does not stick | osu! was running when it was merged. Close osu! and launch it again. |
| Beatmaps not showing up | They are imported on a plain `osu!` launch, not when osu! is opened with a file or link. |

## Credits

- [ppy/osu](https://github.com/ppy/osu): osu!lazer
- [Blur Busters](https://blurbusters.com): beam racing, lagless VSync and the tear line techniques raster sync follows
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL)
- [NixOS/nixpkgs `osu-lazer`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/os/osu-lazer/package.nix): the source build and NuGet lockfile this builds on
- [gaavin/nix-osu-stable](https://github.com/gaavin/nix-osu-stable): the beatmap mirror downloader and settings merge this adapts
