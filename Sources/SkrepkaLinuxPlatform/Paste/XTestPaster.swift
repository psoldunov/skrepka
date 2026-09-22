import CX11
import Foundation

public enum XTestPasteError: Error, CustomStringConvertible {
    case unavailable
    case symbolsMissing
    case displayUnavailable
    case extensionUnavailable
    case injectionFailed

    public var description: String {
        switch self {
        case .unavailable: "libXtst.so.6 is not installed"
        case .symbolsMissing: "libXtst.so.6 does not export the XTest functions"
        case .displayUnavailable: "the X11 display could not be opened"
        case .extensionUnavailable: "the X server does not offer XTest"
        case .injectionFailed: "XTest refused the Ctrl+V key events"
        }
    }
}

/// Sends Ctrl+V through XTest, loading libXtst only for the paste.
public struct XTestPaster: Sendable {
    public init() {}

    public func paste(displayName: String?) throws {
        let result = skrepka_xtest_paste(displayName)
        switch result {
        case 0: return
        case 1: throw XTestPasteError.unavailable
        case 2: throw XTestPasteError.symbolsMissing
        case 3: throw XTestPasteError.displayUnavailable
        case 4: throw XTestPasteError.extensionUnavailable
        default: throw XTestPasteError.injectionFailed
        }
    }
}
