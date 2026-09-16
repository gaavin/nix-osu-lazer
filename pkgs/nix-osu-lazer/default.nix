{
  lib,
  buildDotnetModule,
  buildFHSEnv,
  dotnetCorePackages,
  fetchFromGitHub,
  makeDesktopItem,
  makeWrapper,
  alsa-lib,
  ffmpeg,
  libglvnd,
  libxi,
  lttng-ust,
  numactl,
  pipewire,
  sdl3,
  udev,
  vulkan-loader,
  wayland-protocols,
  writeShellApplication,
  writeText,
  aria2,
  coreutils,
  curl,
  diffutils,
  findutils,
  gawk,
  gnused,
  iproute2,
  unzip,
  # osu! source to build in place of the pinned raster-sync branch, such as a
  # local checkout with `builtins.fetchGit`.
  osuSrc ? null,
  nativeWayland ? true,
  # BASS device update period handed to osu!framework's testing hook, in
  # samples when negative. osu!'s default 10ms period is most of its audio
  # latency; 128 samples keeps pace with a 128-sample PipeWire quantum. null
  # keeps the default.
  bassDevicePeriod ? -128,
  # Load a pipewire-alsa plugin that accepts ALSA periods down to 8 frames and
  # 64 bytes, instead of 64 frames and 128 bytes, in place of the system's.
  lowLatencyPipewireAlsa ? true,
  # Stop the desktop OpenTabletDriver daemon for as long as osu! runs. Turn
  # this off if osu!'s own tablet support is disabled in its settings.
  stopTabletDaemon ? true,
  # `Key = Value` lines merged into game.ini and framework.ini before launch.
  gameSettingsFile ? null,
  frameworkSettingsFile ? null,
  # One beatmap set ID, or one .osk URL, per line. Whatever osu! has not
  # imported yet is downloaded and handed to it at launch.
  beatmapsFile ? null,
  skinsFile ? null,
}:

# osu!lazer built from gaavin/osu's raster-sync branch: ppy/osu master as of
# 2026-09-15 (after 2026.911.0-tachyon) plus raster sync, which times every
# present against the display's scanout so the tear line lands in the blanking
# interval (Graphics > Raster sync). A build from source has its own osu.Game.dll, so the server does not
# accept its scores.
#
# The bundled libSDL3.so is swapped for one that marks the xdg_toplevel surface
# as a game and asks the compositor to tear when vsync is off. Raster sync
# needs those asynchronous flips.

let
  pname = "nix-osu-lazer";
  version = "2026.911.0-unstable-2026-09-15";

  # ppy.SDL3-CS bindings are generated against one SDL commit, and the package
  # ships exactly that build. The replacement has to be the same commit, so the
  # build refuses an SDL3-CS that bundles anything else.
  sdlRevision = "SDL-3.5.0-a8591d9";

  sdl3-patched = sdl3.overrideAttrs (old: {
    version = "3.5.0-unstable-2026-07-20";

    src = fetchFromGitHub {
      owner = "libsdl-org";
      repo = "SDL";
      rev = "a8591d943b7079b17fdd018dc04ec9c71dc94ae4";
      hash = "sha256-bPx7bsdEMl6bMiwZ8QIi4P5YxAjevTci/A+9wx/Ej/g=";
    };

    patches = (old.patches or [ ]) ++ [
      ./sdl3-wayland-game-presentation.patch
    ];

    # SDL generates a client binding for every XML in wayland-protocols/, and
    # vendors neither of these.
    postPatch = old.postPatch + ''
      cp ${wayland-protocols}/share/wayland-protocols/staging/tearing-control/tearing-control-v1.xml \
         ${wayland-protocols}/share/wayland-protocols/staging/content-type/content-type-v1.xml \
         wayland-protocols/
    '';

    # The source tarball has no git metadata, so osu!'s log would otherwise
    # report SDL-3.5.0-GIT-NOTFOUND instead of the commit and this package.
    cmakeFlags = old.cmakeFlags ++ [
      (lib.cmakeFeature "SDL_REVISION" sdlRevision)
      (lib.cmakeFeature "SDL_VENDOR_INFO" pname)
    ];

    doCheck = false;

    # nixpkgs points the changelog at a release tag; this is a bare commit.
    meta = removeAttrs old.meta [ "changelog" ];
  });

  osu = buildDotnetModule rec {
    pname = "osu-lazer-raster-sync";
    inherit version;

    src =
      if osuSrc != null then
        osuSrc
      else
        fetchFromGitHub {
          owner = "gaavin";
          repo = "osu";
          # raster-sync
          rev = "893a82da2bb78e5528b9c32ebf4de6c6010b2acd";
          hash = "sha256-at8jJLc679ctYs5UnKgb2qQLmdp6Irk06R6tvAF1EAc=";
        };

    projectFile = "osu.Desktop/osu.Desktop.csproj";

    # Generated from the branch with `nix build .#default.osu.fetch-deps`.
    nugetDeps = ./deps.json;

    dotnet-sdk = dotnetCorePackages.sdk_10_0;
    dotnet-runtime = dotnetCorePackages.runtime_10_0;

    runtimeDeps = [
      alsa-lib
      ffmpeg
      # Failed to create SDL window. SDL Error: Could not initialize OpenGL / GLES library
      libglvnd
      libxi
      lttng-ust
      numactl
      udev
      vulkan-loader
    ];

    executables = [ "osu!" ];

    postFixup = ''
      if ! grep -aq '${sdlRevision}' $out/lib/${pname}/libSDL3.so; then
        echo "ppy.SDL3-CS no longer bundles ${sdlRevision}:" >&2
        grep -aoE 'SDL-3\.[0-9]+\.[0-9]+-[0-9a-f]+' $out/lib/${pname}/libSDL3.so >&2 || true
        echo "update sdlRevision and the SDL src in pkgs/nix-osu-lazer to that commit." >&2
        exit 1
      fi
      ln -sf ${lib.getLib sdl3-patched}/lib/libSDL3.so.0 $out/lib/${pname}/libSDL3.so
    '';

    meta = {
      license = with lib.licenses; [
        mit
        cc-by-nc-40
        unfreeRedistributable # osu-framework contains libbass.so in repository
      ];
      platforms = [ "x86_64-linux" ];
      mainProgram = "osu!";
    };
  };

  desktopItem = makeDesktopItem {
    name = "osu!";
    desktopName = "osu!";
    comment = "A free-to-win rhythm game. Rhythm is just a *click* away!";
    icon = "osu";
    exec = "osu! %u";
    mimeTypes = [
      "application/x-osu-beatmap-archive"
      "application/x-osu-skin-archive"
      "application/x-osu-beatmap"
      "application/x-osu-storyboard"
      "application/x-osu-replay"
      "x-scheme-handler/osu"
    ];
    categories = [ "Game" ];
    startupWMClass = "osu!";
    startupNotify = true;
    singleMainWindow = true;
  };

  bassDevicePeriodFlag = lib.optionalString (bassDevicePeriod != null) (
    "--set-default OSU_TEMP_TESTING_BASS_CONFIG_DEV_PERIOD ${toString bassDevicePeriod}"
  );

  # BASS reaches PipeWire through ALSA's pipewire PCM plugin, which clamps the
  # period to at least 64 frames (at 48 kHz) and 128 bytes, and asks for that
  # as its node latency.
  pipewire-alsa-patched = pipewire.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./pipewire-alsa-low-latency.patch
    ];
  });

  # NixOS names the plugin by absolute store path in /etc/alsa/conf.d, so
  # ALSA_PLUGIN_DIR is ignored. alsa.conf loads /etc/asound.conf after conf.d,
  # and the later definition wins; ~/.asoundrc still loads after this one.
  asoundConf = writeText "nix-osu-lazer-asound.conf" ''
    pcm_type.pipewire.libs.native = "${pipewire-alsa-patched}/lib/alsa-lib/libasound_module_pcm_pipewire.so"
  '';

  applySettings = writeShellApplication {
    name = "nix-osu-lazer-apply-settings";
    runtimeInputs = [
      coreutils
      diffutils
      gawk
    ];
    text = builtins.readFile ./apply-settings.sh;
  };

  exportSettings = writeShellApplication {
    name = "nix-osu-lazer-export-settings";
    runtimeInputs = [ gawk ];
    text = builtins.readFile ./export-settings.sh;
  };

  exportBeatmaps = writeShellApplication {
    name = "nix-osu-lazer-export-beatmaps";
    runtimeInputs = [
      coreutils
      findutils
      gawk
    ];
    text = builtins.readFile ./export-beatmaps.sh;
  };

  syncContent = writeShellApplication {
    name = "nix-osu-lazer-sync-content";
    runtimeInputs = [
      aria2
      coreutils
      curl
      findutils
      unzip
    ];
    text = builtins.readFile ./sync-content.sh;
  };

  optionalPath = file: lib.optionalString (file != null) "${file}";

  # @osu@ is the wrapped sandbox, which only exists in $out.
  launcher = writeShellApplication {
    name = "osu-launcher";
    runtimeInputs = [
      coreutils
      gnused
      iproute2
    ];
    text = ''
      osu="@osu@"
      stop_tablet_daemon="${lib.optionalString stopTabletDaemon "1"}"
      game_settings="${optionalPath gameSettingsFile}"
      framework_settings="${optionalPath frameworkSettingsFile}"
      beatmaps="${optionalPath beatmapsFile}"
      skins="${optionalPath skinsFile}"
      apply_settings_bin="${lib.getExe applySettings}"
      export_settings_bin="${lib.getExe exportSettings}"
      export_beatmaps_bin="${lib.getExe exportBeatmaps}"
      sync_content_bin="${lib.getExe syncContent}"
      # game.ini and framework.ini exactly as a fresh install of this release
      # writes them, for --export-settings to compare against.
      factory_game="${./factory-game.ini}"
      factory_framework="${./factory-framework.ini}"

    ''
    + builtins.readFile ./launcher.sh;
  };
in
# A sandbox with its own /etc, so the low-latency ALSA plugin can shadow the
# system's for osu! alone. /dev stays visible, for the DRM vblank timestamps
# raster sync follows.
buildFHSEnv {
  inherit pname version;

  runScript = "${osu}/bin/osu!";

  # fix OpenGL renderer on nvidia + wayland
  extraBwrapArgs = [
    "--ro-bind-try /etc/egl/egl_external_platform.d /etc/egl/egl_external_platform.d"
  ]
  ++ lib.optional lowLatencyPipewireAlsa "--ro-bind ${asoundConf} /etc/asound.conf";

  extraInstallCommands = ''
    . ${makeWrapper}/nix-support/setup-hook
    mv -v $out/bin/${pname} $out/bin/osu!

    wrapProgram $out/bin/osu! \
      ${lib.optionalString nativeWayland "--set SDL_VIDEODRIVER wayland"} \
      ${bassDevicePeriodFlag} \
      --set OSU_EXTERNAL_UPDATE_PROVIDER 1

    install -m 444 -D ${desktopItem}/share/applications/*.desktop -t $out/share/applications
    for i in 16 32 48 64 96 128 256 512 1024; do
      install -D ${osu.src}/assets/lazer.png $out/share/icons/hicolor/''${i}x$i/apps/osu.png
    done

    mkdir -p $out/libexec
    mv $out/bin/osu! $out/libexec/osu!
    substitute ${lib.getExe launcher} $out/bin/osu! --replace-fail @osu@ $out/libexec/osu!
    chmod 555 $out/bin/osu!
  '';

  passthru = {
    inherit
      osu
      sdl3-patched
      pipewire-alsa-patched
      applySettings
      exportSettings
      exportBeatmaps
      syncContent
      ;
  };

  meta = {
    description = "osu!lazer built with raster sync (beam-raced presents), declarative settings, beatmaps and skins, presenting on Wayland as a tearing game surface";
    homepage = "https://github.com/gaavin/nix-osu-lazer";
    license = osu.meta.license;
    platforms = [ "x86_64-linux" ];
    mainProgram = "osu!";
  };
}
