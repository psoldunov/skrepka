import Foundation
import SkrepkaLinuxUI

// The desktop app: tray, picker and Settings in one process. Everything it does
// is in Sources/SkrepkaLinuxUI/, where the tests can reach it; this only hands
// the exit status back.
exit(SkrepkaApplication.run())
