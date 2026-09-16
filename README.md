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
| Raster sync | `RasterSyncMode` | `TearlineSync` | `Disabled`, `TearlineSync` (one present per refresh), `FrameSlices` (several per refresh, with fixed tear lines between slices) or `CursorChasing` (`TearlineSync` plus a tear line just above the cursor) |
| Frame slices per refresh | `RasterFrameSlices` | `4` | 2 to 16, `FrameSlices` mode only. The most slices per refresh: fewer are used while frames take too long to fill every slice |
| Render headroom | `RasterRenderHeadroom` | `0.5` | Milliseconds kept spare on top of recent render times. How much of the recent spread is covered steers itself, so about 2% of frames finish late and the rest start as late, and show a scene as new, as they can. The steering absorbs this setting: plays from 0 to 0.25 ms measured the same margin, the same share finishing late and the same latency, so 0 is a fine place to leave it |
| Show tear line indicator | `RasterShowTearline` | `false` | Strip down the left edge, coloured by frame slice (or by present outside `FrameSlices`) |

The tear line offset is automatic. osu! measures how long the compositor takes to flip each frame and steers the tear line into the blanking interval during a play. Finished plays are stored in `~/.local/share/osu/raster-sync-flips.json` and seed the next play. **Forget recorded flips** clears them.

### Checking the tear line

Turn on **Show tear line indicator**. Where a tear line crosses the strip, it shows both colours. With the tear line in blanking the strip flickers evenly with no split. With frame slices, the strip is coloured by slice instead, so it holds still: neighbouring slices differ in colour, except the top and bottom ones with an odd number of slices. A band two slices tall means a slice got no frame of its own. The status note shows how many slices are in use, how many were skipped, and how many timed frames the next frame overtook before they flipped. While playing, the runtime log (`~/.local/share/osu/logs/*.runtime.log`) gets the same numbers every second, followed by a line of timings at p50/p99/max: render, split into the draw thread's own work and its wait for the GPU, then how late the draw thread woke, the swap call, the rest of the frame loop, and how late presents started. Another line says where a frame's time went whenever the slice count changes. A third counts the collections that ran in each part of a present — while the draw thread slept, or while it was drawing, waiting for the GPU, waiting for the scanline or swapping — with the pause the runtime reports for them and how much was allocated to earn each one. The note under the checkbox shows the current steering target.

With several displays lit, pick the one osu! is on:

```bash
OSU_RASTER_DRM_DEVICE=/dev/dri/card1 OSU_RASTER_CRTC=<id> osu!
```

### Choosing how gameplay collects garbage

Gameplay leaves the gen0 budget alone, so it grows to about 16 MB and collects a fifth of a time a second. osu! asks for `LowLatency` upstream, which instead pins the budget at 256 KiB however large it is asked to be: measured in a play, that is 15.7 collections a second pausing 0.61 ms each, against 0.2 a second. Leaving it alone measured fourteen times less pause time, 0.19 ms off the margin a frame starts on, and a whole extra frame slice per refresh, with nothing finishing late. To go back for a play:

```bash
OSU_GAMEPLAY_GC_MODE=LowLatency osu!
```

Takes `Interactive` (the default), `SustainedLowLatency` or `LowLatency`, and the log says which one a play started with. `DOTNET_GCgen0size` (hex bytes) only does anything in the first two, since `LowLatency` overrides it.

While a play is paced, the collection that is due is held back until the gap before a frame starts drawing, where it delays nothing already on its way to the screen. A collection lasts longer than that gap, so the present it precedes is aimed a slice or two further down the screen to make room, giving up a slice roughly every five seconds. Those are counted apart from skipped slices, which are uneven pacing rather than a choice. To leave collections where they fall:

```bash
OSU_RASTER_GC_PACING=0 osu!
```

### How quickly the slice count climbs

More slices mean each frame is aimed at a nearer scanline, so it shows a newer scene: the whole of the gap between presents is frame age. A refresh is split into more of them once a frame fits inside 90% of one and keeps fitting for a while, and the count drops the moment one stops fitting. Measured in play, the count sat a slice below what the frame times allowed for about half of every second, because a single present that failed to qualify threw the whole wait away. A dip now only pauses it. Both timings can be set for a play:

```bash
OSU_RASTER_SLICE_RAISE_MS=1000 OSU_RASTER_SLICE_GRACE_MS=250 osu!
```

Those are the defaults; `2000` and `0` restore the behaviour from before. Measured in play, though, how quickly it climbs turns out to matter little: it changed how often the count sat below what the frames allowed, from 57% of seconds to 45%, while leaving the count itself at 3.7 of a possible 7 either way.

What actually limits the count is how strict the fit has to be: a refresh is split into as many slices as all but the slowest 1% of frames fit inside. Measured on one map, judging it on the slowest 1% rather than the slowest 0.1% took the count from 3.7 slices to 6.3, and the gap between presents — which is how old a frame is by the time it is scanned out — from 1.88 ms to 1.11 ms. It is paid for in slices that go without a frame of their own, which rose from 0.3 a second to 7.2, still under one slice in a hundred.

To go back to judging it on the slowest tenth of a percent:

```bash
OSU_RASTER_SLICE_FIT=0.999 osu!
```

The default is `0.99`. Stricter means steadier tear lines and older frames; looser means the reverse, and the skipped slices in the log and in the status note are what it spends.

Note that the count cannot pass **Frame slices per refresh** in the settings, and in play it now reaches it, so that slider is worth raising past its default before anything else is tuned.

### How late a frame is allowed to be

A frame is drawn as late as its measured render time allows, so the scene it shows is as new as possible, and how late that is steers itself: the prediction is pushed down until about 2% of frames finish after their scanline. That margin is the half of frame age the slice count does not decide — measured in play, 0.79 ms of margin against a 1.09 ms gap between presents. Letting more frames finish late shaves the margin, and pays for it in tear lines landing past the scanline they were aimed at:

```bash
OSU_RASTER_LATE_TARGET=0.05 osu!
```

The default is `0.02`. The status note and the log both show the margin and the share finishing late, so the two can be watched against each other.

### How old the scene is when drawing starts

A frame shows input and time as they were when the update frame that built its scene started, and that scene is older than the render margin alone: it took an update frame to build, then waited for the draw thread to wake. With the frame limiter lifted during a play the update thread used to run flat out with nothing lining it up with the draw, so that wait was anything up to another update frame. Update frames can be timed to finish just before the draw thread wakes for them:

```bash
OSU_RASTER_UPDATE_SYNC=fill osu!      # timed, with frames that would finish earlier still run
OSU_RASTER_UPDATE_SYNC=aligned osu!   # only the timed frame, one update per present
```

The default is off, because measured in play it made scenes older: 1.61 ms at present against 1.26 ms running free. Frames were aimed to finish in time at their slowest percent, so the typical one finished half a millisecond early, and a finished scene only ever sat 0.17 ms before the draw woke. The `Raster sync update:` log line gives the scene's age at present and at draw start.

### The cursor at the newest pen report

The gameplay cursor is drawn where the pen is when the frame is drawn, not where it was when the update frame read input: each report is seen as it leaves OpenTabletDriver, and the draw moves the cursor by however far the pen has travelled since. Only a cursor sitting on one of the pen's recent reports is moved, so replays, autoplay and mice are left alone. Hits are still judged where the update frame had the cursor, and the trail follows update frames. To turn it off:

```bash
OSU_POINTER_LATCH=0 osu!      # off
OSU_POINTER_LATCH=draw osu!   # moved as the scene draws it, without a tear line of its own
```

### A tear line for the cursor

With **Raster sync** on **Cursor chasing**, each refresh gets one more tear line, just above the cursor, and the cursor is drawn last on that present: after the rest of the frame has finished on the GPU, at the newest pen report. Measured in play, a report reaches the present 0.04 ms after it is taken, against 0.72 ms moving the cursor as the scene draws it. The rest of the frame is unchanged, so only that one present per refresh does the extra work.

It is Lagless VSync's present in the blanking interval plus the cursor's: two presents a refresh. It felt far better than the same tear line alongside frame slices, where the cursor's present crowded out 1.6 slices a refresh and pacing was uneven, so it is a mode of its own and Lagless VSync is unchanged. The blanking interval's present is never given up: a cursor low on the screen has its tear line pulled up far enough for a whole frame to fit before the blanking interval's, and a cursor high on the screen is drawn on the blanking interval's present instead.

```bash
OSU_CURSOR_TEARLINE_LEAD=32 osu!    # scanlines between the tear line and the top of the cursor
OSU_CURSOR_TEARLINE_BANDS=7 osu!    # hold the tear line to 7 positions a refresh instead of following the cursor
OSU_POINTER_LATCH_WAIT_GPU=1 osu!   # wait for the GPU to finish the cursor before presenting
```

A tear line that moves still costs some pacing: each band of the screen it passes over changes from the blanking interval's frame to the cursor's, a one-off step of up to half a refresh.

### Measurements

The `Raster sync` log lines, and everything measured for them, are only built in on request, since measuring costs the draw thread time on every frame:

```nix
programs.nix-osu-lazer.package = pkgs.nix-osu-lazer.override { rasterMetrics = true; };
```

With them, `Raster sync pacing:` gives, for 8 bands of scanlines, how far the scene shown there stepped from exactly one refresh to the next, which is frame pacing as it reaches the screen; `Raster sync cursor:` gives the pen's report rate and spacing, how often update frames had the cursor on the pen, how far draws moved it, how old the newest report was when drawn and how long after that the frame was presented.

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

Raster sync log, in a build with `rasterMetrics = true`:

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
| Fewer slices in use than set | Frames take longer than a slice to render and swap. The runtime log line for the change says which part took the time. Lower **Render headroom** or accept the lower count. A count is dropped as soon as it stops fitting, and only raised once a frame fits in 90% of a slice for two seconds, so a frame time near a slice boundary holds the lower count rather than flapping. The count is judged on all but the slowest 0.1% of frames, since a frame that overruns its slice leaves the next slice without a frame of its own, which shows as uneven pacing rather than latency. |
| Status reports overtaken frames | The compositor is not flipping frames before the next arrives. Lower **Frame slices per refresh**. |
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
- vestaia from thePooN's Discord server: pipewire-alsa patches
- [libsdl-org/SDL](https://github.com/libsdl-org/SDL)
- [nixpkgs `osu-lazer`](https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/by-name/os/osu-lazer/package.nix)
- [gaavin/nix-osu-stable](https://github.com/gaavin/nix-osu-stable)
