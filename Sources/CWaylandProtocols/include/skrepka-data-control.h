// The two `wl_interface` symbols `wl_registry_bind` needs, behind accessors.
//
// The only hand-written file in this target. `wayland-scanner` writes
// everything else here and `scripts/regenerate-wayland-protocols.sh` rewrites
// exactly the files it wrote — `<stem>-client-protocol.h` and
// `<stem>-protocol.c` — so this one survives a regeneration untouched.
//
// Why it exists at all: binding a global out of the registry needs the address
// of the protocol's `wl_interface`, and libwayland stores that pointer inside
// the proxy for the proxy's whole life. The generated headers declare the
// symbols but expose no way to take their address, and reaching them from Swift
// means `withUnsafePointer(to:)` on an imported C global — which was measured
// to yield the real symbol address rather than a copy, but is not contractually
// promised to, and escaping the pointer past the closure is outside that API's
// stated contract either way. Six lines of C are cheaper than depending on an
// unspecified detail that would fail silently and intermittently.

#ifndef SKREPKA_DATA_CONTROL_H
#define SKREPKA_DATA_CONTROL_H

#include "ext-data-control-v1-client-protocol.h"
#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "wlr-data-control-unstable-v1-client-protocol.h"
#include <linux/memfd.h>
#include <sys/syscall.h>
#include <unistd.h>

static inline const struct wl_interface *skrepka_ext_data_control_manager_interface(void) {
	return &ext_data_control_manager_v1_interface;
}

static inline const struct wl_interface *skrepka_wlr_data_control_manager_interface(void) {
	return &zwlr_data_control_manager_v1_interface;
}

static inline const struct wl_interface *skrepka_virtual_keyboard_manager_interface(void) {
	return &zwp_virtual_keyboard_manager_v1_interface;
}

static inline int skrepka_keymap_memfd(const char *bytes, unsigned int size) {
	int fd = (int)syscall(SYS_memfd_create, "skrepka-keymap", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, size) < 0) {
		if (fd >= 0) close(fd);
		return -1;
	}
	unsigned int written = 0;
	while (written < size) {
		ssize_t count = write(fd, bytes + written, size - written);
		if (count <= 0) {
			close(fd);
			return -1;
		}
		written += (unsigned int)count;
	}
	return fd;
}

// Core protocol, not generated here, and needed for the same reason: a data
// device is per-seat, so binding one means binding a wl_seat first.
static inline const struct wl_interface *skrepka_wl_seat_interface(void) {
	return &wl_seat_interface;
}

#endif /* SKREPKA_DATA_CONTROL_H */
