{
  description = "Skrepka — clipboard history for the Linux desktop, synced with your other machines";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The release binaries are x86_64 only; scripts/build-deck.sh says why.
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      skrepkaVariants = pkgs: import ./nix/packages.nix { inherit pkgs self; };

      app = pkgs: program: description: {
        type = "app";
        program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka}/bin/${program}";
        meta.description = description;
      };
    in
    {
      # `release` is the tarball a GitHub release ships; `master` is compiled
      # from this flake's own commit. Both install as `skrepka` with the same
      # identity, so a system carries one or the other. `linux-dev-env` is the
      # Swift 6.3 toolchain and every library the Linux targets link, for
      # building from this checkout; scripts/linux-env.sh builds and enters it.
      packages = forAllSystems (
        pkgs:
        let
          variants = skrepkaVariants pkgs;
        in
        variants
        // {
          skrepka = variants.release;
          default = variants.release;
        }
      );

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

      overlays.default =
        final: _prev:
        let
          variants = skrepkaVariants final;
        in
        {
          skrepka = variants.release;
          skrepka-master = variants.master;
        };

      nixosModules.default = import ./nix/nixos-module.nix self;
      homeManagerModules.default = import ./nix/home-manager-module.nix self;

      checks = forAllSystems (pkgs: {
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.skrepka;
      });
    };
}
