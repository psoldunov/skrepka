# Skrepka's Linux release, repackaged for Nix.
#
# The x86_64 tarball scripts/build-deck.sh builds and every GitHub release
# carries, patched to run against nixpkgs' libraries rather than rebuilt: the
# binaries link the Swift runtime statically and need only glibc, GTK 4 and a
# handful of X11 and Wayland libraries from the system. A source build waits
# for nixpkgs' Swift 6 to have some track record; packaging/README.md says why.
#
# scripts/update-nix-release.sh rewrites `version` and `hash` for each release.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  wrapGAppsHook4,
  gtk4,
  gtk4-layer-shell,
  glib,
  cairo,
  pango,
  gdk-pixbuf,
  sqlite,
  wayland,
  libx11,
  libxfixes,
  libxtst,
}:

let
  appId = "dev.soldunov.Skrepka.App";
  extensionUuid = "skrepka@dev.soldunov";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "skrepka";
  version = "0.3.0";

  src = fetchurl {
    url = "https://github.com/psoldunov/skrepka/releases/download/v${finalAttrs.version}/skrepka-linux-x86_64.tar.gz";
    hash = "sha256-lqTZB/JQfI9KG4WWkDmQcgEQjoG5hdhXqIRyPQH2K/U=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    gtk4-layer-shell
    glib
    cairo
    pango
    gdk-pixbuf
    sqlite
    wayland
    libx11
    libxfixes
    # libstdc++ and libgcc_s.
    stdenv.cc.cc.lib
  ];

  # Loaded with dlopen, by name, for automatic paste on X11 only, so
  # autoPatchelfHook cannot see it among the binaries' NEEDED entries.
  runtimeDependencies = [ libxtst ];

  dontConfigure = true;
  dontBuild = true;
  # scripts/build-deck.sh already stripped the debug info and kept the symbol
  # table on purpose, so a crash backtrace still names its functions.
  dontStrip = true;

  # skrepka-gui alone is a GTK app; the daemon and the CLI need no wrapper.
  dontWrapGApps = true;

  # The tarball's own lib/ holds the libgtk4-layer-shell it bundles for
  # SteamOS. It is not installed: nixpkgs' gtk4-layer-shell takes its place,
  # patched in like every other library.
  installPhase = ''
    runHook preInstall

    install -Dm755 -t $out/bin bin/skrepkad bin/skrepka bin/skrepka-gui

    install -Dm644 packaging/systemd/skrepkad.service $out/lib/systemd/user/skrepkad.service
    substituteInPlace $out/lib/systemd/user/skrepkad.service \
      --replace-fail "ExecStart=%h/.local/bin/skrepkad" "ExecStart=$out/bin/skrepkad"

    install -Dm644 packaging/dbus/dev.soldunov.Skrepka.service \
      $out/share/dbus-1/services/dev.soldunov.Skrepka.service
    substituteInPlace $out/share/dbus-1/services/dev.soldunov.Skrepka.service \
      --replace-fail "Exec=skrepkad" "Exec=$out/bin/skrepkad"

    # The autostart entry goes in share/skrepka rather than etc/xdg/autostart.
    # A profile's etc/xdg is on $XDG_CONFIG_DIRS on NixOS, so an entry there
    # would start the app for anyone with the package installed, whatever a
    # module's `autostart` option says. The modules put it where it belongs.
    install -Dm644 packaging/desktop/${appId}.desktop $out/share/applications/${appId}.desktop
    install -Dm644 packaging/autostart/${appId}.desktop $out/share/skrepka/autostart/${appId}.desktop
    for entry in $out/share/applications/${appId}.desktop $out/share/skrepka/autostart/${appId}.desktop; do
      substituteInPlace "$entry" --replace-fail "Exec=skrepka-gui" "Exec=$out/bin/skrepka-gui"
    done

    mkdir -p $out/share/icons
    cp -R packaging/icons/hicolor $out/share/icons/hicolor

    install -Dm644 -t $out/share/gnome-shell/extensions/${extensionUuid} \
      gnome-extension/metadata.json gnome-extension/extension.js gnome-extension/dbus.js \
      gnome-extension/limits.js gnome-extension/README.md

    runHook postInstall
  '';

  # Settings writes this command into a fresh autostart entry. The wrapper's
  # own path is in this generation's store path, which garbage collection
  # deletes after an upgrade; the name on PATH outlives it.
  preFixup = ''
    gappsWrapperArgs+=(--set-default SKREPKA_GUI_EXECUTABLE skrepka-gui)
    wrapGApp $out/bin/skrepka-gui
  '';

  passthru = {
    inherit extensionUuid;
  };

  meta = {
    description = "Clipboard history for the Linux desktop, synced with your other machines";
    homepage = "https://github.com/psoldunov/skrepka";
    changelog = "https://github.com/psoldunov/skrepka/blob/master/CHANGELOG.md";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "skrepka-gui";
  };
})
