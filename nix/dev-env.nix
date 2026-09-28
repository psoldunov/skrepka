# The Linux development environment: Swift 6.3 and everything the Linux targets
# link, inside an FHS sandbox so the official toolchain runs unmodified.
#
#   nix build .#linux-dev-env -o .build-linux/nix-dev-env
#   .build-linux/nix-dev-env/bin/skrepka-dev swift build --product SkrepkaLinux
#   nix develop                      an interactive shell inside it
#
# scripts/linux-env.sh does the first two for you, and every Linux script goes
# through it; nothing here needs to be run by hand.
#
# Why not nixpkgs' own `swift`: it is 5.10.1 in every nixpkgs this flake could
# pin, and Package.swift needs tools-version 6.2. Why FHS rather than
# patchelf: the swift.org toolchain's clang looks for glibc's headers under
# /usr/include, its crt objects under /usr/lib and GCC's runtime under
# /usr/lib/gcc, and the binaries it links ask for /lib64/ld-linux-x86-64.so.2.
# Rewriting all of that is a toolchain port; a bubblewrap sandbox that provides
# those paths is not.
#
# `pkgs` is NOT the flake's main nixpkgs. nix/packages.nix passes nixos-24.05,
# whose glibc 2.39, GLib 2.80, GTK 4.14, Wayland 1.22, SQLite 3.45 and sway 1.9
# are the versions Ubuntu 24.04 ships — the base of the build image and the
# floor the release tarball, and the flake's `master` package, are built
# against. With current nixpkgs (GLib 2.88, GTK
# 4.22) SkrepkaLinuxUI does not compile: newer GLib's flag enums import into
# Swift as option sets, so `G_DBUS_CALL_FLAGS_NONE` and seven more constants
# are not found, and `gdk_texture_new_for_pixbuf` is deprecated, which this
# package treats as an error. Matching the container also means a native gate
# and a container gate check the same thing.
#
# The toolchain is the same release as the build image's `swift:6.3-noble`
# base (Swift 6.3.3, docker tag 6.3.3-noble, per swift.org's release API on
# 2026-09-28). Release builds still go through the container —
# scripts/build-deck.sh — which is where the release floor is defined.
#
# x86_64 only, like the release. An aarch64 toolchain exists for the same
# release; adding it is one more `fetchurl` hash, not a design change.
{
  lib,
  stdenvNoCC,
  fetchurl,
  runCommand,
  buildFHSEnv,
  writeShellScript,
  pkgs,
  # From the flake's main nixpkgs: 24.05 packages SwiftLint for macOS only, and
  # the build image pins 0.65.1, which is what current nixpkgs ships as a
  # static Linux binary.
  swiftlint,
}:

let
  swiftVersion = "6.3.3";

  toolchain = stdenvNoCC.mkDerivation {
    pname = "swift-toolchain";
    version = swiftVersion;

    src = fetchurl {
      url = "https://download.swift.org/swift-${swiftVersion}-release/ubuntu2404/swift-${swiftVersion}-RELEASE/swift-${swiftVersion}-RELEASE-ubuntu24.04.tar.gz";
      hash = "sha256-2oJypf3czWWxUp7Q5S4EUm4urdQjfVjWIg7+uXPGzRk=";
    };

    dontConfigure = true;
    dontBuild = true;
    # The binaries run inside the FHS sandbox, which supplies the loader and
    # the libraries they expect. Patching or stripping them would only break
    # the toolchain's own relative lookups.
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a usr/. $out/
      runHook postInstall
    '';

    meta = {
      description = "The swift.org Swift ${swiftVersion} toolchain for Ubuntu 24.04";
      homepage = "https://www.swift.org/install/linux/";
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  # libcurl with versioned symbols, as Ubuntu builds it. Foundation's
  # networking library asks for `CURL_OPENSSL_4`-versioned symbols; nixpkgs'
  # curl carries no symbol versions, which works but makes every SwiftPM
  # invocation print "no version information available" first.
  curlVersioned = pkgs.curl.overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--enable-versioned-symbols" ];
    doCheck = false;
  });

  # Libraries the toolchain asks for by their Ubuntu 24.04 names or builds,
  # which nixpkgs' copies do not answer to:
  #
  #   libncurses.so.6, libtinfo.so.6  nixpkgs builds only the wide-character
  #       library, and its compatibility symlinks under those names carry the
  #       SONAME libncursesw.so.6 — so ldconfig files them under that name, and
  #       the sandbox's loader, which consults the cache rather than searching
  #       /usr/lib, never finds them. `swift` fails to start.
  #   libcurl.so.4  the versioned build above.
  #
  # A directory of those names on LD_LIBRARY_PATH is searched by file name
  # instead, and keeps the second libcurl out of /usr, where it would collide
  # with the one git and the rest of the closure bring.
  toolchainCompat = runCommand "swift-toolchain-compat-libs" { } ''
    mkdir -p $out/lib
    for name in ncurses form panel; do
      ln -s ${pkgs.ncurses}/lib/lib''${name}w.so.6 $out/lib/lib''${name}.so.6
    done
    ln -s ${pkgs.ncurses}/lib/libncursesw.so.6 $out/lib/libtinfo.so.6
    ln -s ${curlVersioned.out}/lib/libcurl.so.4 $out/lib/libcurl.so.4
  '';

  # What the Ubuntu 24.04 swift.org toolchain expects from the system, in
  # nixpkgs' names, plus what this package links: the same list as
  # docker/Dockerfile.linux, which is the reference for the Linux gate.
  directPackages = with pkgs; [
    # The toolchain's own runtime and link-time needs.
    binutils
    curl
    gcc.cc
    gcc.cc.lib
    git
    glibc
    libedit
    libuuid
    libxml2
    ncurses
    python3
    sqlite
    tzdata
    unzip
    z3
    zlib
    pkg-config

    # What Package.swift's system-library targets resolve through pkg-config.
    # gtk4-layer-shell is 1.0.2 here against the image's 1.3.0, built from
    # source there because noble does not package it; every function
    # Sources/CGtk4 calls is in both.
    gtk4
    gtk4-layer-shell
    glib
    cairo
    pango
    gdk-pixbuf
    wayland
    wayland-scanner
    wayland-protocols
    xorg.libX11
    xorg.libXfixes
    xorg.libXtst

    # Named in the Requires.private of the .pc files above but not propagated,
    # because nixpkgs' own pkg-config only reads Requires.private for --static.
    # SwiftPM reads them for cflags too, and one missing module makes it drop
    # that target's whole cflags chain — `'glib-unix.h' file not found` in
    # CGtk4, with nothing but a "couldn't find pc file" warning to say why.
    fribidi
    libthai
    libdatrie
    libselinux
    libsepol
    libsysprof-capture
    pcre2
    xorg.libXdmcp

    # The headless compositor and clipboard clients the live Wayland and X11
    # suites drive. scripts/doctor-linux.sh sets SKREPKA_REQUIRE_HEADLESS, so
    # a missing one here is a failure rather than a silent skip.
    sway
    xorg.xorgserver
    wl-clipboard
    xclip
    wtype
    grim
  ];

  # pkg-config's Requires chains reach packages nobody named, so the sandbox
  # gets the propagatedBuildInputs closure of the list above, not only the list.
  targetPackages = lib.closePropagation directPackages ++ [ swiftlint ];

  runScript = writeShellScript "skrepka-dev-run" ''
    if [ "$#" -eq 0 ]; then
      exec bash
    fi
    exec "$@"
  '';
in
buildFHSEnv {
  name = "skrepka-dev";
  targetPkgs = _: targetPackages;
  # Headers and .pc files live in `dev` outputs, which buildFHSEnv leaves out
  # by default.
  extraOutputsToInstall = [ "dev" ];
  inherit runScript;

  profile = ''
    export PATH="${toolchain}/bin:$PATH"
    export LD_LIBRARY_PATH="${toolchainCompat}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    # Some packages, wayland-protocols among them, ship their .pc in
    # share/pkgconfig rather than lib/pkgconfig.
    export PKG_CONFIG_PATH="/usr/lib/pkgconfig:/usr/share/pkgconfig"
    # The Linux SwiftLint binary loads SourceKit at runtime; the toolchain lives
    # outside /usr, so it has to be told where.
    export LINUX_SOURCEKIT_LIB_PATH="${toolchain}/lib"
    # Lets scripts/lib/linux-env.sh recognise it is already inside.
    export SKREPKA_LINUX_ENV=nix
  '';

  passthru = {
    inherit toolchain swiftVersion;
  };

  meta = {
    description = "Skrepka's Linux build environment: Swift ${swiftVersion} and the libraries it links";
    platforms = [ "x86_64-linux" ];
  };
}
