{
  lib,
  appimageTools,
  fetchFromGitHub,
  makeWrapper,
  osu-lazer-bin,
  sdl3,
  wayland-protocols,
  writeShellApplication,
  aria2,
  coreutils,
  curl,
  diffutils,
  findutils,
  gawk,
  gnused,
  iproute2,
  unzip,
  nativeWayland ? true,
  # BASS device update period handed to osu!framework's testing hook, in
  # samples when negative. osu!'s default 10ms period is most of its audio
  # latency; 128 samples keeps pace with a 128-sample PipeWire quantum. null
  # keeps the default.
  bassDevicePeriod ? -128,
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

# The official AppImage, so score submission and multiplayer keep working: the
# server checks the MD5 of osu.Game.dll, which is left untouched. Only the
# bundled libSDL3.so is swapped for one that marks the xdg_toplevel surface as
# a game and asks the compositor to tear when vsync is off.

let
  pname = "nix-osu-lazer";
  inherit (osu-lazer-bin) version src;

  # ppy.SDL3-CS bindings are generated against one SDL commit, and the release
  # ships exactly that build. The replacement has to be the same commit, so
  # the extraction below refuses a release that bundles anything else.
  sdlRevision = "SDL-3.5.0-f0e99e7";

  sdl3-patched = sdl3.overrideAttrs (old: {
    version = "3.5.0-unstable-2026-06-28";

    src = fetchFromGitHub {
      owner = "libsdl-org";
      repo = "SDL";
      rev = "f0e99e7c7f9aa90d5ce2e3b8a69f72c23faf257e";
      hash = "sha256-sRas/PqkNkulfY/ybsUfRezrrSPTOMJ6AwktaMrpNVM=";
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

  contents = appimageTools.extract {
    inherit pname version src;
    postExtract = ''
      if ! grep -aq '${sdlRevision}' $out/usr/bin/libSDL3.so; then
        echo "osu! ${version} no longer bundles ${sdlRevision}:" >&2
        grep -aoE 'SDL-3\.[0-9]+\.[0-9]+-[0-9a-f]+' $out/usr/bin/libSDL3.so >&2 || true
        echo "update sdlRevision and the SDL src in pkgs/${pname} to that commit." >&2
        exit 1
      fi
      chmod u+w $out/usr/bin
      rm -f $out/usr/bin/libSDL3.so
      install -m 555 ${lib.getLib sdl3-patched}/lib/libSDL3.so.0 $out/usr/bin/libSDL3.so
    '';
  };

  bassDevicePeriodFlag = lib.optionalString (bassDevicePeriod != null) (
    "--set-default OSU_TEMP_TESTING_BASS_CONFIG_DEV_PERIOD ${toString bassDevicePeriod}"
  );

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

  # @osu@ is the wrapped AppImage, which only exists in $out.
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
appimageTools.wrapAppImage {
  inherit pname version contents;

  extraPkgs = pkgs: with pkgs; [ icu ];

  # fix OpenGL renderer on nvidia + wayland
  extraBwrapArgs = [
    "--ro-bind-try /etc/egl/egl_external_platform.d /etc/egl/egl_external_platform.d"
  ];

  extraInstallCommands = ''
    . ${makeWrapper}/nix-support/setup-hook
    mv -v $out/bin/${pname} $out/bin/osu!

    wrapProgram $out/bin/osu! \
      ${lib.optionalString nativeWayland "--set SDL_VIDEODRIVER wayland"} \
      ${bassDevicePeriodFlag} \
      --set OSU_EXTERNAL_UPDATE_PROVIDER 1

    install -m 444 -D ${contents}/osu!.desktop -t $out/share/applications
    for i in 16 32 48 64 96 128 256 512 1024; do
      install -D ${contents}/osu.png $out/share/icons/hicolor/''${i}x$i/apps/osu.png
    done

    mkdir -p $out/libexec
    mv $out/bin/osu! $out/libexec/osu!
    substitute ${lib.getExe launcher} $out/bin/osu! --replace-fail @osu@ $out/libexec/osu!
    chmod 555 $out/bin/osu!
  '';

  passthru = {
    inherit
      sdl3-patched
      applySettings
      exportSettings
      exportBeatmaps
      syncContent
      ;
  };

  meta = osu-lazer-bin.meta // {
    description = "osu!lazer official AppImage with declarative settings, beatmaps and skins, presenting on Wayland as a tearing game surface";
    platforms = [ "x86_64-linux" ];
    mainProgram = "osu!";
  };
}
