import Foundation
import SkrepkaLinuxUI

// The Settings window. Everything it does is in Sources/SkrepkaLinuxUI/Settings/,
// where the tests can reach it; this only hands the exit status back.
exit(SettingsApplication.run())
