# The master variant: Skrepka compiled from this flake's own commit the way
# scripts/build-deck.sh compiles a release, then packaged by ./package.nix
# exactly as the release tarball is — the same patching, wrapping and layout.
#
# The compile runs inside ./dev-env.nix, the FHS sandbox holding the swift.org
# toolchain and Ubuntu 24.04's libraries, so the binaries are built against
# the same floor the release tarball is. That sandbox is bubblewrap, nested in
# Nix's own build sandbox, so the build machine has to allow unprivileged user
# namespaces — NixOS does by default.
#
# The build sandbox has no network, so everything SwiftPM would clone comes
# from one fixed-output derivation, `deps`: the checkouts `swift package
# resolve` makes from Package.resolved, without their .git directories, and
# the workspace-state.json that records them. Its hash lives in ./pins.json and
# goes stale whenever Package.resolved changes; refresh it with
# `scripts/pin-master-deps.sh`.
{
  lib,
  stdenvNoCC,
  cacert,
  writableTmpDirAsHomeHook,
  release,
  devEnv,
  self,
  depsHash,
}:
let
  pname = "skrepka-master";

  # DaemonVersion.current, the version every release bumps and
  # `skrepkad --version` reports.
  daemonVersionPath = "Sources/SkrepkaDaemon/DaemonVersion.swift";
  daemonVersionMatches = lib.filter (match: match != null) (
    map (builtins.match ''.*static let current = "([^"]+)".*'') (
      lib.splitString "\n" (builtins.readFile (../. + "/${daemonVersionPath}"))
    )
  );
  baseVersion =
    if daemonVersionMatches == [ ] then
      throw "nix/master.nix: no `static let current` in ${daemonVersionPath}"
    else
      builtins.head (builtins.head daemonVersionMatches);

  commitTime = self.lastModifiedDate;
  commitDate = lib.concatStringsSep "-" [
    (builtins.substring 0 4 commitTime)
    (builtins.substring 4 2 commitTime)
    (builtins.substring 6 2 commitTime)
  ];
  shortRev = self.shortRev or self.dirtyShortRev or "unknown";

  # What `skrepkad --version` and `skrepka doctor` report, so a running daemon
  # names the commit it was built from.
  appVersion = "${baseVersion}-master.${builtins.substring 0 8 commitTime}.g${shortRev}";
  version = "${baseVersion}-unstable-${commitDate}";

  # One `swift build` per product, as in scripts/build-deck.sh: given
  # `--product` twice, it builds only the last one.
  products = [
    "skrepkad"
    "skrepka"
    "skrepka-gui"
  ];

  # SwiftPM loads every target to resolve, so resolving needs the sources too,
  # not only the manifest and Package.resolved.
  swiftPackage = lib.fileset.unions [
    ../Package.swift
    ../Package.resolved
    ../Sources
    ../Tests
  ];

  # `--force-resolved-versions` makes a stale Package.resolved an error rather
  # than a fresh resolution, so the checkouts are always exactly its pins.
  swiftpmFlags = [
    "--scratch-path"
    ".build"
    "--disable-dependency-cache"
    "--force-resolved-versions"
  ];

  # A fixed-output path depends only on its name and hash, so a stale hash
  # would silently reuse the old checkouts. Naming it after Package.resolved
  # and the toolchain that resolves it forces a fetch, and with it a hash
  # mismatch, whenever either moves.
  resolvedDigest = builtins.substring 0 16 (
    builtins.hashString "sha256" (devEnv.swiftVersion + builtins.readFile ../Package.resolved)
  );

  deps = stdenvNoCC.mkDerivation {
    name = "skrepka-swiftpm-deps-${resolvedDigest}";

    src = lib.fileset.toSource {
      root = ../.;
      fileset = swiftPackage;
    };

    nativeBuildInputs = [
      devEnv
      writableTmpDirAsHomeHook
    ];

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    # Nix's build sandbox has no /etc/ssl for git to find GitHub's roots in.
    env.GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      skrepka-dev swift package resolve ${lib.escapeShellArgs swiftpmFlags}

      runHook postBuild
    '';

    # Each checkout's .git holds packfiles and an index that differ from one
    # clone to the next. SwiftPM builds from the files and workspace-state.json
    # alone, and does not look for .build/repositories while the checkouts
    # match the pins.
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R .build/checkouts $out/checkouts
      cp .build/workspace-state.json $out/workspace-state.json
      find $out/checkouts -mindepth 2 -maxdepth 2 -name .git -exec rm -rf {} +

      runHook postInstall
    '';

    # A fixed-output derivation may not refer to other store paths, and fixup
    # would write some in (patched shebangs, for one).
    dontFixup = true;

    outputHash = depsHash;
    outputHashMode = "recursive";
  };

  # The payload layout scripts/build-deck.sh stages — bin/, packaging/ and
  # gnome-extension/ side by side — which is what ./package.nix installs from.
  unwrapped = stdenvNoCC.mkDerivation {
    pname = "${pname}-unwrapped";
    inherit version;

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        swiftPackage
        ../packaging
        ../gnome-extension
      ];
    };

    nativeBuildInputs = [
      devEnv
      writableTmpDirAsHomeHook
    ];

    postPatch = ''
      substituteInPlace ${daemonVersionPath} \
        --replace-fail 'current = "${baseVersion}"' 'current = "${appVersion}"'
    '';

    configurePhase = ''
      runHook preConfigure

      mkdir -p .build
      cp -R ${deps}/checkouts .build/checkouts
      cp ${deps}/workspace-state.json .build/workspace-state.json
      chmod -R u+w .build

      runHook postConfigure
    '';

    # --static-swift-stdlib, as for the release: the binaries carry the Swift
    # runtime, and need only glibc, GTK 4 and the rest from the system, which
    # ./package.nix patches in.
    buildPhase = ''
      runHook preBuild

      for product in ${lib.escapeShellArgs products}; do
        skrepka-dev swift build ${lib.escapeShellArgs swiftpmFlags} \
          -c release --static-swift-stdlib --product "$product"
      done

      runHook postBuild
    '';

    # Debug info off, symbols kept, as scripts/build-deck.sh strips a release:
    # a crash backtrace still names its functions.
    installPhase = ''
      runHook preInstall

      mkdir -p stage/bin
      for product in ${lib.escapeShellArgs products}; do
        install -m755 ".build/release/$product" "stage/bin/$product"
      done
      skrepka-dev strip --strip-debug stage/bin/*

      mkdir -p $out
      cp -R stage/bin packaging gnome-extension $out/

      runHook postInstall
    '';

    # ./package.nix patches the binaries once, against the consumer's nixpkgs.
    dontFixup = true;

    # Anything here would pin the toolchain and the 24.05 libraries into the
    # installed closure.
    disallowedReferences = [
      deps
      devEnv
      devEnv.toolchain
    ];
  };
in
release.overrideAttrs (old: {
  inherit pname version;
  src = unwrapped;

  passthru = old.passthru // {
    inherit appVersion deps unwrapped;
  };

  meta = old.meta // {
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})
