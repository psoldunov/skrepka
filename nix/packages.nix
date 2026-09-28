# Both variants of Skrepka, and the development environment the master variant
# compiles in. The flake's `packages` and its overlay both come through here,
# so they cannot drift.
#
#   release  the GitHub release's tarball, repackaged (./package.nix)
#   master   compiled from this flake's own commit (./master.nix)
#
# Both install the same binaries under the same app ID, so a system carries one
# or the other.
{ pkgs, self }:
let
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  system = pkgs.stdenv.hostPlatform.system;

  # nixos-24.05 (its final commit), whose libraries are the versions Ubuntu
  # 24.04 ships — the development environment builds against these rather
  # than against `pkgs`, and ./dev-env.nix says why. Fetched here, by hash,
  # rather than declared as a flake input, so that nobody who only installs
  # the release or a module downloads a second nixpkgs for it.
  nixpkgsNoble = import (builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    rev = "b134951a4c9f3c995fd7be05f3243f8ecd65d798";
    narHash = "sha256-OnSAY7XDSx7CtDoqNh8jwVwh4xNL/2HaJxGjryLWzX8=";
  }) { inherit system; };

  release = pkgs.callPackage ./package.nix { };

  # The Swift 6.3 toolchain and every library the Linux targets link, for
  # building from a checkout. scripts/linux-env.sh builds and enters it.
  linux-dev-env = nixpkgsNoble.callPackage ./dev-env.nix {
    inherit (pkgs) swiftlint;
  };
in
{
  inherit release linux-dev-env;

  master = pkgs.callPackage ./master.nix {
    inherit release self;
    devEnv = linux-dev-env;
    depsHash = pins.deps.${system} or (throw "nix/pins.json has no deps hash for ${system}");
  };
}
