{
  description = "osu!lazer on NixOS with SDL presenting as a tearing Wayland game surface";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      packages = rec {
        osu-lazer-tearing = pkgs.callPackage ./pkgs/osu-lazer-tearing { };
        default = osu-lazer-tearing;
      };
    in
    {
      packages.${system} = packages;

      apps.${system}.default = {
        type = "app";
        program = "${packages.osu-lazer-tearing}/bin/osu!";
        meta.description = "Launch osu!lazer";
      };

      # Built from the consumer's package set rather than this flake's, so the
      # AppImage and SDL track whatever osu-lazer-bin the system already has.
      overlays.default = final: _prev: {
        osu-lazer-tearing = final.callPackage ./pkgs/osu-lazer-tearing { };
      };
    };
}
