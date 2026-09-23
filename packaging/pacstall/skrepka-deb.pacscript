# The .deb every Skrepka release carries, installed as it is. This file is
# kept in https://github.com/psoldunov/skrepka under packaging/pacstall/,
# where each release pins it and scripts/test-pacstall.sh installs it.
pkgname="skrepka-deb"
gives="skrepka"
pkgver="0.3.0"
pkgdesc="Clipboard history for the Linux desktop, synced with your other machines"
url="https://github.com/psoldunov/skrepka"
license=("MIT")
arch=("amd64")
repology=("project: ${gives}")
source=("${url}/releases/download/v${pkgver}/skrepka-linux-x86_64.deb")
sha256sums=("8d6331a1b872ee4353c89b43515b4425a87523cbd0466163fb218a954f294ad4")
# The .deb needs glibc 2.38 and GTK 4.12: Ubuntu 24.04 and Debian 13 onwards.
incompatible=("*:jammy" "*:bookworm")
maintainer=("Philipp Soldunov <69530789+psoldunov@users.noreply.github.com>")
