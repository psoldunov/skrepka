#!/usr/bin/env bash
#
# Regenerates the C bindings in Sources/CWaylandProtocols/ from the protocol
# XML vendored beside them.
#
#   scripts/regenerate-wayland-protocols.sh
#
# Run it from macOS and it re-enters the Linux Swift container, which is where
# wayland-scanner lives; run it on Linux and it runs natively. It writes
# generated files only — it never touches the network and never reads a
# system copy of either protocol.
#
# Why the XML is vendored rather than taken from the distribution's
# wayland-protocols package:
#
#   ext-data-control-v1  is a *staging* protocol first shipped in
#                        wayland-protocols 1.39. Ubuntu noble ships 1.45 and has
#                        it; jammy ships 1.25 and does not. A build that reads
#                        the system copy compiles on one LTS and fails on the
#                        other, for a file that changes about once a year.
#   wlr-data-control-v1  is in the wlr-protocols repository and is packaged by
#                        no Debian or Fedora package at all. There is no system
#                        copy to read.
#
# Why the generated C is checked in rather than produced by a build-tool plugin:
# the protocol XML changes rarely, generated code is reviewable in a diff, and a
# build that needs wayland-scanner on every machine is a build that fails on the
# one machine that matters. scripts/doctor-linux.sh therefore needs neither this
# script nor wayland-scanner.
#
# Re-run this after editing anything in protocol-xml/, and commit what it
# changes. The output is a pure function of the XML and the scanner version, so
# a diff with no XML change means the scanner moved — say so in the commit.
#
# It rewrites exactly two files per protocol — include/<stem>-client-protocol.h
# and <stem>-protocol.c — and touches nothing else, so the one hand-written file
# in that target, include/skrepka-data-control.h, survives a regeneration.

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="Sources/CWaylandProtocols"
XML_DIR="${TARGET}/protocol-xml"
INCLUDE_DIR="${TARGET}/include"

if [[ "$(uname -s)" != "Linux" ]]; then
	printf '\033[1m▸ delegating to the Linux container\033[0m\n'
	exec scripts/linux.sh scripts/regenerate-wayland-protocols.sh "$@"
fi

if ! command -v wayland-scanner > /dev/null 2>&1; then
	echo "wayland-scanner is not on PATH." >&2
	echo "It ships in libwayland-bin (apt) / wayland-devel (yum); the Skrepka" >&2
	echo "Linux image carries it — see docker/Dockerfile.linux." >&2
	exit 1
fi

mkdir -p "${INCLUDE_DIR}"

for xml in "${XML_DIR}"/*.xml; do
	stem="$(basename "${xml}" .xml)"
	printf '\033[1m▸ %s\033[0m\n' "${stem}"

	# --strict fails the run on a DTD violation rather than emitting code from a
	# malformed description. A vendored file that has been edited by hand is
	# exactly the case worth catching here.
	wayland-scanner --strict client-header "${xml}" "${INCLUDE_DIR}/${stem}-client-protocol.h"
	wayland-scanner --strict private-code "${xml}" "${TARGET}/${stem}-protocol.c"

	# private-code, not public-code: these symbols are linked into one static
	# library and nothing outside it resolves them, so exporting them from the
	# DSO would only invite a collision with a system copy of the same protocol.
	echo "  → include/${stem}-client-protocol.h"
	echo "  → ${stem}-protocol.c"
done

printf '\n\033[32m✓ regenerated with %s\033[0m\n' "$(wayland-scanner --version 2>&1)"
