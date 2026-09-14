{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatMapStrings
    concatStrings
    elemAt
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  cfg = config.programs.nix-osu-lazer;

  settingsType = types.attrsOf (
    types.oneOf [
      types.bool
      types.int
      types.float
      types.str
    ]
  );

  # toString gives floats six decimals; osu! writes 0.5 and 1.0.
  formatFloat =
    f:
    let
      m = builtins.match "(-?[0-9]+)\\.([0-9]*[1-9])?0*" (toString f);
    in
    if m == null then
      toString f
    else
      "${elemAt m 0}.${if elemAt m 1 == null then "0" else elemAt m 1}";

  formatValue =
    v:
    if builtins.isBool v then
      (if v then "True" else "False")
    else if builtins.isFloat v then
      formatFloat v
    else
      toString v;

  settingsFile =
    name: attrs:
    if attrs == { } then
      null
    else
      pkgs.writeText name (concatStrings (mapAttrsToList (k: v: "${k} = ${formatValue v}\n") attrs));

  manifestFile =
    name: entries:
    if entries == [ ] then null else pkgs.writeText name (concatMapStrings (e: "${toString e}\n") entries);

  gameSettingsFile = settingsFile "nix-osu-lazer-game.ini" cfg.settings;
  frameworkSettingsFile = settingsFile "nix-osu-lazer-framework.ini" cfg.frameworkSettings;
  beatmapsFile = manifestFile "nix-osu-lazer-beatmaps.txt" cfg.beatmaps;
  skinsFile = manifestFile "nix-osu-lazer-skins.txt" cfg.skins;

  finalPackage = cfg.package.override {
    inherit
      gameSettingsFile
      frameworkSettingsFile
      beatmapsFile
      skinsFile
      ;
  };

  osu = lib.escapeShellArg (lib.getExe finalPackage);
in
{
  options.programs.nix-osu-lazer = {
    enable = mkEnableOption "osu!lazer with declarative settings, beatmaps and skins";

    package = mkOption {
      type = types.package;
      default = pkgs.nix-osu-lazer or (pkgs.callPackage ../../pkgs/nix-osu-lazer { });
      defaultText = literalExpression "pkgs.nix-osu-lazer";
      example = literalExpression "pkgs.nix-osu-lazer.override { bassDevicePeriod = -256; }";
      description = ''
        The nix-osu-lazer package. The settings, beatmaps and skins below are
        passed to it with `.override`, so overrides such as
        `bassDevicePeriod` can be set here.
      '';
    };

    settings = mkOption {
      type = settingsType;
      default = { };
      example = {
        DimLevel = 1.0;
        BeatmapSkins = false;
        Skin = "cffa69de-b3e3-4dee-8563-3c4f425c05d0";
      };
      description = ''
        Keys merged into `game.ini` on activation and before every launch. Keys
        left out keep whatever osu! saved. Booleans become `True`/`False`.

        `Skin` takes a skin's ID, not its name. The built-in skins have fixed
        IDs: argon `cffa69de-b3e3-4dee-8563-3c4f425c05d0`, argon pro
        `9fc9cf5d-0f16-4c71-8256-98868321ac43`, triangles
        `2991cfd8-2140-469a-bcb9-2ec23fbce4ad`, classic
        `81f02cd3-eec6-4865-ac23-fae26a386187` and retro
        `0555c76a-cc6b-4bb4-9548-df76ba72ef25`. An imported skin gets a new ID
        every time it is imported.

        `osu! --export-settings` prints what differs from a fresh install.
        `Token`, the saved login, is refused.
      '';
    };

    frameworkSettings = mkOption {
      type = settingsType;
      default = { };
      example = {
        FrameSync = "Unlimited";
        Renderer = "OpenGL";
        VolumeUniversal = 0.8;
      };
      description = ''
        Keys merged into `framework.ini` (renderer, frame limiter, window mode,
        audio device and volume) on activation and before every launch.
      '';
    };

    beatmaps = mkOption {
      type = types.listOf types.ints.positive;
      default = [ ];
      example = [
        75
        1011011
      ];
      description = ''
        Beatmap set IDs to keep imported. Missing sets are downloaded from
        mirrors on activation and handed to osu! at the next launch. A set
        deleted in game comes back two launches later, since osu! only removes
        a deleted set's files while it starts.
      '';
    };

    skins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "https://example.com/MySkin.osk" ];
      description = ''
        URLs of `.osk` skin archives to keep imported, downloaded and handed to
        osu! the same way as beatmaps.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.any (k: lib.toLower k == "token") (lib.attrNames cfg.settings));
        message = "programs.nix-osu-lazer.settings must not set Token; the saved login stays in game.ini.";
      }
      {
        assertion = lib.all (url: builtins.match "https?://.+" url != null) cfg.skins;
        message = "programs.nix-osu-lazer.skins entries must be http(s) URLs to .osk files.";
      }
    ];

    home.packages = [ finalPackage ];

    # Downloads only: nothing but osu! itself can import into its database.
    home.activation.nixOsuLazer = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.optionalString (gameSettingsFile != null || frameworkSettingsFile != null) ''
        run ${osu} --apply-settings
      ''
      + lib.optionalString (beatmapsFile != null || skinsFile != null) ''
        run ${osu} --sync-content || true
      ''
    );
  };
}
