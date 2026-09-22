# `programs.skrepka` for NixOS: the package installed for every user, the way
# the .deb and the .rpm install it (packaging/README.md).
#
# The launcher entry, the icons and the GNOME extension arrive through
# environment.systemPackages. The autostart entry goes in /etc/xdg/autostart
# unless `autostart` is off; Settings reads it as the system entry and hides it
# per user. The daemon's D-Bus activation file and user unit arrive through
# services.dbus.packages and systemd.packages, and the unit is wanted by every
# user's default.target, as install.sh's `systemctl --user enable` has it.
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

    autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to start skrepka-gui in the tray at every user's login, from
        /etc/xdg/autostart. Each user can still turn it off in Settings.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    services.dbus.packages = [ cfg.package ];
    systemd.packages = [ cfg.package ];
    systemd.user.services.skrepkad.wantedBy = [ "default.target" ];

    environment.etc."xdg/autostart/dev.soldunov.Skrepka.App.desktop" = lib.mkIf cfg.autostart {
      source = "${cfg.package}/share/skrepka/autostart/dev.soldunov.Skrepka.App.desktop";
    };
  };
}
