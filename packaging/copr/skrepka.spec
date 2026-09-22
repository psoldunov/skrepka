# Skrepka's Linux release, repackaged for Fedora and published on COPR.
#
# The x86_64 tarball scripts/build-deck.sh builds and every GitHub release
# carries, laid out for a system install rather than rebuilt: the binaries link
# the Swift runtime statically and need only glibc, GTK 4, gtk4-layer-shell and
# a handful of X11 and Wayland libraries, which rpm reads from their ELF NEEDED
# entries and turns into Requires by itself.
#
# The layout is packaging/nfpm.yaml's, file for file, with one exception: the
# private libgtk4-layer-shell the tarball bundles for SteamOS is left out.
# Fedora 43 and newer ship gtk4-layer-shell 1.3.0, the same version, and the
# binary finds it in /usr/lib64 once its $ORIGIN/../lib/skrepka rpath comes up
# empty.
#
# No scriptlets, for nfpm.yaml's reason: nothing runs as root at install time
# and nothing is enabled for every user. At login the autostart entry starts
# skrepka-gui, whose first call on the session bus starts skrepkad through the
# D-Bus activation file and the user unit.
#
# scripts/pin-release.sh rewrites Version for each release. scripts/test-copr.sh
# builds and installs it in Fedora containers, and scripts/publish-copr.sh
# builds the source package and uploads it. packaging/README.md explains all
# three.

%global app_id dev.soldunov.Skrepka.App
%global dbus_name dev.soldunov.Skrepka
%global extension_uuid skrepka@dev.soldunov
%global asset skrepka-linux-x86_64

# Nothing is compiled, so there is no debug info to split out: build-deck.sh
# already stripped it, and kept the symbol table on purpose so a crash
# backtrace still names its functions.
%global debug_package %{nil}

Name:           skrepka
Version:        0.3.0
Release:        1%{?dist}
Summary:        Clipboard history for the Linux desktop, synced with your other machines
License:        MIT
URL:            https://github.com/psoldunov/skrepka
# The asset name carries no version, so the fragment gives the downloaded copy
# one: two releases never share a file name in a source cache.
Source0:        %{url}/releases/download/v%{version}/%{asset}.tar.gz#/%{asset}-%{version}.tar.gz
# The tarball carries no LICENSE of its own.
Source1:        https://raw.githubusercontent.com/psoldunov/skrepka/v%{version}/LICENSE

ExclusiveArch:  x86_64

BuildRequires:  desktop-file-utils
BuildRequires:  systemd-rpm-macros

# The icon theme owns the hicolor directories the icons go into.
Requires:       hicolor-icon-theme
# Loaded with dlopen, by name, for automatic paste on X11 only, so rpm cannot
# see it among the binaries' NEEDED entries.
Recommends:     libXtst
# Peer discovery browses and publishes through Avahi, and answers mDNS itself
# where Avahi refuses, so Avahi helps but is not required.
Suggests:       avahi

%description
Skrepka records what you copy, opens a searchable picker on a global shortcut,
and syncs history with paired Linux machines and Macs over the local network.

This package installs skrepkad (the daemon, as a systemd user service started
on demand over D-Bus), skrepka (the CLI) and skrepka-gui (tray icon, picker and
Settings), plus a GNOME Shell extension that captures copies on GNOME Wayland.
On GNOME, log out and back in once after installing, then run
`gnome-extensions enable skrepka@dev.soldunov`.

%prep
%setup -q -n %{asset}
cp -p %{SOURCE1} LICENSE

%build
# Nothing to build: the tarball carries the release binaries.

%install
# replace_line FILE OUT FROM TO: FILE with its one line equal to FROM replaced
# by TO, written to OUT. Exactly one, as in scripts/build-packages.sh: a unit
# or service file whose line was renamed or duplicated fails the build rather
# than shipping a stale path.
replace_line() {
    local file="$1" out="$2" from="$3" to="$4" count
    count="$(grep -Fxc -- "${from}" "${file}" || true)"
    if [ "${count}" != "1" ]; then
        echo "error: expected exactly one '${from}' line in ${file}, found ${count}." >&2
        exit 1
    fi
    mkdir -p "$(dirname "${out}")"
    FROM="${from}" TO="${to}" awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' \
        "${file}" > "${out}"
    chmod 0644 "${out}"
}

install -Dpm0755 -t %{buildroot}%{_bindir} bin/skrepkad bin/skrepka bin/skrepka-gui

# The unit ships pointing at ~/.local/bin and the D-Bus file at a bare name,
# both of which install.sh rewrites; a system install points them at /usr/bin.
# The D-Bus specification wants an absolute Exec=.
replace_line packaging/systemd/skrepkad.service \
    %{buildroot}%{_userunitdir}/skrepkad.service \
    'ExecStart=%%h/.local/bin/skrepkad' 'ExecStart=%{_bindir}/skrepkad'
replace_line packaging/dbus/%{dbus_name}.service \
    %{buildroot}%{_datadir}/dbus-1/services/%{dbus_name}.service \
    'Exec=skrepkad' 'Exec=%{_bindir}/skrepkad'

# The launcher and autostart entries name skrepka-gui bare, which /usr/bin on
# every session's PATH resolves.
install -Dpm0644 packaging/desktop/%{app_id}.desktop \
    %{buildroot}%{_datadir}/applications/%{app_id}.desktop
install -Dpm0644 packaging/autostart/%{app_id}.desktop \
    %{buildroot}%{_sysconfdir}/xdg/autostart/%{app_id}.desktop

mkdir -p %{buildroot}%{_datadir}/icons
cp -pR packaging/icons/hicolor %{buildroot}%{_datadir}/icons/hicolor

# The five files install.sh copies into the extension directory.
install -Dpm0644 -t %{buildroot}%{_datadir}/gnome-shell/extensions/%{extension_uuid} \
    gnome-extension/metadata.json gnome-extension/extension.js gnome-extension/dbus.js \
    gnome-extension/limits.js gnome-extension/README.md

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{app_id}.desktop
desktop-file-validate %{buildroot}%{_sysconfdir}/xdg/autostart/%{app_id}.desktop
grep -Fq '"uuid": "%{extension_uuid}"' \
    %{buildroot}%{_datadir}/gnome-shell/extensions/%{extension_uuid}/metadata.json

%files
%license LICENSE
%{_bindir}/skrepkad
%{_bindir}/skrepka
%{_bindir}/skrepka-gui
%{_userunitdir}/skrepkad.service
%{_datadir}/dbus-1/services/%{dbus_name}.service
%{_datadir}/applications/%{app_id}.desktop
# A user who edits it keeps the edit across upgrades. Turning launch at login
# off in Settings does not edit it: it hides it from ~/.config/autostart, which
# the Autostart spec lets override this one.
%config(noreplace) %{_sysconfdir}/xdg/autostart/%{app_id}.desktop
%{_datadir}/icons/hicolor/*/apps/%{app_id}.png
%{_datadir}/icons/hicolor/scalable/status/skrepka-tray.svg
# Co-owned rather than required: the extension is for GNOME, and the package
# is not, so it does not pull in gnome-shell to own these two.
%dir %{_datadir}/gnome-shell
%dir %{_datadir}/gnome-shell/extensions
%{_datadir}/gnome-shell/extensions/%{extension_uuid}/

# One entry, for the version pinned above: scripts/pin-release.sh rewrites it
# with each release, and CHANGELOG.md is where the history lives. rpmbuild takes
# the build's timestamps from its date, which keeps the build reproducible.
%changelog
* Tue Sep 22 2026 Philipp Soldunov <69530789+psoldunov@users.noreply.github.com> - 0.3.0-1
- Skrepka 0.3.0: https://github.com/psoldunov/skrepka/blob/v0.3.0/CHANGELOG.md
