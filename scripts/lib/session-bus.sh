# shellcheck shell=bash
#
# Asking the session bus who owns a name, without starting anything. Sourced by
# scripts/run-linux.sh and scripts/lib/dev-session.sh.
#
# NameHasOwner and not a call to the name itself, which is the whole point:
# calling dev.soldunov.Skrepka while nothing owns it makes the bus activate the
# installed daemon through packaging/dbus/dev.soldunov.Skrepka.service — the
# very copy a dev run has just stopped.

# session_bus_name_owned <name> — 0 if owned, 1 if not, 2 if nothing here can ask.
session_bus_name_owned() {
	local name="$1" reply
	if command -v busctl > /dev/null 2>&1; then
		reply="$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus \
			org.freedesktop.DBus NameHasOwner s "${name}" 2> /dev/null)" || return 2
		[[ "${reply}" == "b true" ]]
	elif command -v gdbus > /dev/null 2>&1; then
		reply="$(gdbus call --session --dest org.freedesktop.DBus \
			--object-path /org/freedesktop/DBus \
			--method org.freedesktop.DBus.NameHasOwner "${name}" 2> /dev/null)" || return 2
		[[ "${reply}" == "(true,)" ]]
	elif command -v dbus-send > /dev/null 2>&1; then
		reply="$(dbus-send --session --print-reply --dest=org.freedesktop.DBus \
			/org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner "string:${name}" 2> /dev/null)" || return 2
		[[ "${reply}" == *"boolean true"* ]]
	else
		return 2
	fi
}
