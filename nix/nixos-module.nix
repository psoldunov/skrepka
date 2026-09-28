# `programs.skrepka` for NixOS: the package installed for every user, the way
# the .deb and the .rpm install it (packaging/README.md).
#
# The launcher entry, the icons and the GNOME extension arrive through
# environment.systemPackages. The autostart entry goes in /etc/xdg/autostart
# unless `autostart` is off; Settings reads it as the system entry and hides it
# per user. The daemon's D-Bus activation file and user unit arrive through
# services.dbus.packages and systemd.packages, and the unit is wanted by every
# user's default.target, as install.sh's `systemctl --user enable` has it.
#
# `openFirewall` is the one option that works without `enable`. NixOS's
# firewall is on and drops every port nobody opened, and Home Manager cannot
# open one — so a system that installs Skrepka per user through the Home
# Manager module imports this module too, for the firewall alone.
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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open the ports other devices reach Skrepka on: TCP 27182
        for sync, TCP 27183 for pairing, and UDP 5353 for mDNS discovery.
        Without them a paired Mac or Linux machine can see this one but never
        connect to it — pairing started there fails, and nothing copied there
        reaches this clipboard, while everything still works the other way
        round.

        Takes effect whether or not `enable` is set, so a system that installs
        Skrepka through the Home Manager module can set this alone. It opens
        skrepkad's default ports only; with `--port N`, open N and N+1 in
        networking.firewall instead.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];
      services.dbus.packages = [ cfg.package ];
      systemd.packages = [ cfg.package ];
      systemd.user.services.skrepkad.wantedBy = [ "default.target" ];

      environment.etc."xdg/autostart/dev.soldunov.Skrepka.App.desktop" = lib.mkIf cfg.autostart {
        source = "${cfg.package}/share/skrepka/autostart/dev.soldunov.Skrepka.App.desktop";
      };
    })

    (lib.mkIf cfg.openFirewall {
      # SkrepkaPorts in Sources/SkrepkaIPC/SkrepkaPorts.swift — change both
      # together.
      networking.firewall.allowedTCPPorts = [
        27182
        27183
      ];
      # skrepkad answers mDNS itself when avahi will not publish for it, and
      # needs the queries to reach it either way.
      networking.firewall.allowedUDPPorts = [ 5353 ];
    })
  ];
}
