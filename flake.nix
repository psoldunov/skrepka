{
  description = "Skrepka — clipboard history for the Linux desktop, synced with your other machines";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The release binaries are x86_64 only; scripts/build-deck.sh says why.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      app = pkgs: program: description: {
        type = "app";
        program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka}/bin/${program}";
        meta.description = description;
      };

      # nixos-24.05 (its final commit), whose libraries are the versions Ubuntu
      # 24.04 ships — the development environment builds against these rather
      # than against `nixpkgs`, and nix/dev-env.nix says why. Fetched here, by
      # hash, rather than declared as a flake input, so that nobody who only
      # installs the package or a module downloads a second nixpkgs for it.
      nixpkgsNoble =
        system:
        import (builtins.fetchTree {
          type = "github";
          owner = "NixOS";
          repo = "nixpkgs";
          rev = "b134951a4c9f3c995fd7be05f3243f8ecd65d798";
          narHash = "sha256-OnSAY7XDSx7CtDoqNh8jwVwh4xNL/2HaJxGjryLWzX8=";
        }) { inherit system; };
    in
    {
      packages = forAllSystems (pkgs: {
        skrepka = pkgs.callPackage ./nix/package.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka;
        # The Swift 6.3 toolchain and every library the Linux targets link,
        # for building from this checkout. scripts/linux-env.sh builds and
        # enters it; nix/dev-env.nix says why it is an FHS sandbox.
        linux-dev-env = (nixpkgsNoble pkgs.stdenv.hostPlatform.system).callPackage ./nix/dev-env.nix {
          inherit (pkgs) swiftlint;
        };
      });

      # `nix develop` drops into the same sandbox interactively.
      devShells = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.linux-dev-env.env;
      });

      # For trying it out. A real install wants one of the modules, which put
      # the daemon on the session bus and start it at login.
      apps = forAllSystems (pkgs: {
        default = app pkgs "skrepka-gui" "The tray icon, the clipboard picker and Settings";
        skrepka-gui = app pkgs "skrepka-gui" "The tray icon, the clipboard picker and Settings";
        skrepka = app pkgs "skrepka" "The Skrepka command line";
        skrepkad = app pkgs "skrepkad" "The clipboard-history daemon, in the foreground";
      });

      overlays.default = final: _prev: {
        skrepka = final.callPackage ./nix/package.nix { };
      };

      nixosModules.default = import ./nix/nixos-module.nix self;
      homeManagerModules.default = import ./nix/home-manager-module.nix self;

      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka;
      });
    };
}
