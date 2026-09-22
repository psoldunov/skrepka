# `programs.skrepka` for Home Manager: what install.sh does, declaratively, for
# Nix on any distribution — a Steam Deck included.
#
# The files go where install.sh puts them, because those are the directories a
# session reads whether or not it knows about Nix: the D-Bus activation file in
# ~/.local/share/dbus-1/services, the user unit in ~/.config/systemd/user and
# enabled, the launcher entry and icons in ~/.local/share. Each is a link into
# the package, so an upgrade is a `home-manager switch`.
#
# The autostart entry is the exception. Settings turns launch at login off by
# writing `Hidden=true` into ~/.config/autostart, which it cannot do to a link
# into the store, and Home Manager would refuse the next switch over the file
# Settings put in its place. So it is written once, as an ordinary file, only
# when there is none — the way install.sh keeps a hidden entry hidden. With
# `autostart` off nothing is written, and nothing else starts the app: the
# package keeps its entry out of the profile's etc/xdg (see nix/package.nix).
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.skrepka;
  appId = "dev.soldunov.Skrepka.App";
  busName = "dev.soldunov.Skrepka";
  unit = "${cfg.package}/lib/systemd/user/skrepkad.service";
  autostartPath = "${config.xdg.configHome}/autostart/${appId}.desktop";

  # The package's autostart entry, starting the profile's skrepka-gui rather
  # than this generation's store path, so it keeps working after the store
  # path is collected.
  autostartEntry = pkgs.runCommand "${appId}.desktop" { } ''
    substitute ${cfg.package}/share/skrepka/autostart/${appId}.desktop $out \
      --replace-fail "Exec=${cfg.package}/bin/skrepka-gui" \
        "Exec=${config.home.profileDirectory}/bin/skrepka-gui"
  '';
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
        Whether to start skrepka-gui in the tray at login. The entry is
        written once, when ~/.config/autostart has none, so turning launch at
        login off in Settings sticks.
      '';
    };

    gnomeExtension = lib.mkEnableOption ''
      the GNOME Shell extension that records copies on GNOME Wayland, linked
      into ~/.local/share/gnome-shell/extensions. Enable it once with
      `gnome-extensions enable skrepka@dev.soldunov` after logging out and back
      in. To manage it with programs.gnome-shell.extensions instead, list
      config.programs.skrepka.package there — that option replaces the whole
      enabled-extensions list, which is why this one does not set it
    '';
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ];

        xdg.dataFile = {
          "dbus-1/services/${busName}.service".source = "${cfg.package}/share/dbus-1/services/${busName}.service";
          "applications/${appId}.desktop".source = "${cfg.package}/share/applications/${appId}.desktop";
          "icons/hicolor" = {
            source = "${cfg.package}/share/icons/hicolor";
            recursive = true;
          };
        };

        xdg.configFile = {
          "systemd/user/skrepkad.service".source = unit;
          "systemd/user/default.target.wants/skrepkad.service".source = unit;
        };
      }

      (lib.mkIf cfg.autostart {
        home.activation.skrepkaAutostart = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          entry=${lib.escapeShellArg autostartPath}
          if [[ ! -e "$entry" && ! -L "$entry" ]]; then
            run mkdir -p "$(dirname "$entry")"
            run install -m 0644 ${autostartEntry} "$entry"
          fi
        '';
      })

      (lib.mkIf cfg.gnomeExtension {
        xdg.dataFile."gnome-shell/extensions/${cfg.package.extensionUuid}".source =
          "${cfg.package}/share/gnome-shell/extensions/${cfg.package.extensionUuid}";
      })
    ]
  );
}
