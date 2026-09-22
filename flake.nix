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
    in
    {
      packages = forAllSystems (pkgs: {
        skrepka = pkgs.callPackage ./nix/package.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka;
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
