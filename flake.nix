{
  description = "osu!lazer on NixOS with raster sync (beam-raced presents), declarative settings, beatmaps and skins, presenting as a tearing Wayland game surface";

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
        nix-osu-lazer = pkgs.callPackage ./pkgs/nix-osu-lazer { };
        default = nix-osu-lazer;
      };
    in
    {
      packages.${system} = packages;

      apps.${system}.default = {
        type = "app";
        program = "${packages.nix-osu-lazer}/bin/osu!";
        meta.description = "Launch osu!lazer";
      };

      # Built from the consumer's package set rather than this flake's, so the
      # .NET SDK, SDL and PipeWire follow the system's nixpkgs.
      overlays.default = final: _prev: {
        nix-osu-lazer = final.callPackage ./pkgs/nix-osu-lazer { };
      };

      # Uses pkgs.nix-osu-lazer when the overlay is applied, and otherwise
      # builds the package from the consumer's pkgs all the same.
      homeModules.nix-osu-lazer = ./modules/home-manager/nix-osu-lazer.nix;
      homeModules.default = self.homeModules.nix-osu-lazer;
    };
}
