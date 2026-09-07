// The one header libwayland-client publishes, behind a name SwiftPM can point
// a module map at.
//
// A module map cannot `header <wayland-client.h>` — the directive takes a path
// relative to the map, not an include search. Naming an absolute
// /usr/include/wayland-client.h would work on Debian and break on anything that
// installs elsewhere, so the shim is the portable spelling: pkg-config supplies
// the include path, the preprocessor resolves the angle brackets, and this file
// is the only thing the map has to know the location of.

#include <wayland-client.h>
