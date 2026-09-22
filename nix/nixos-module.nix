# `programs.skrepka` for NixOS: the package installed for every user, the way
# the .deb and the .rpm install it (packaging/README.md).
#
# The launcher entry, the icons, the GNOME extension and the autostart entry
# arrive through environment.systemPackages — the last in the system profile's
# etc/xdg/autostart, on $XDG_CONFIG_DIRS, which Settings reads as the system
# entry and hides per user. The daemon's D-Bus activation file and user unit
# arrive through services.dbus.packages and systemd.packages, and the unit is
# wanted by every user's default.target, as install.sh's
# `systemctl --user enable` has it.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.skrepka;
in
{
  options.programs.skrepka = {
    enable = lib.mkEnableOption "Skrepka, the clipboard-history daemon, CLI and tray app";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "skrepka.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The Skrepka package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    services.dbus.packages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    systemd.user.services.skrepkad.wantedBy = [ "default.target" ];
  };
}
