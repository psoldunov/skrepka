// Umbrella for the system sqlite3 headers.
//
// Included rather than pointing the module map straight at /usr/include so the
// header search stays pkg-config's business: libsqlite3-dev puts sqlite3.h in
// a different place on Debian and on Fedora, and hard-coding either breaks the
// other.
#include <sqlite3.h>
