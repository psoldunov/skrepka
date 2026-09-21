enum AppearanceParser {
    static func colorScheme(from value: DBusValue) -> AppearancePreference.ColorScheme? {
        guard let raw = unwrapped(value).uint32Value else { return nil }
        switch raw {
        case 1: return .dark
        case 2: return .light
        default: return .noPreference
        }
    }

    static func accent(from value: DBusValue) -> RGBColor? {
        guard
            let channels = unwrapped(value).children,
            channels.count == 3,
            case .double(let red) = channels[0],
            case .double(let green) = channels[1],
            case .double(let blue) = channels[2],
            (0...1).contains(red),
            (0...1).contains(green),
            (0...1).contains(blue)
        else { return nil }
        return RGBColor(red: red, green: green, blue: blue)
    }

    static func settingChange(_ value: DBusValue) -> (String, DBusValue)? {
        guard
            let children = value.children,
            children.count == 3,
            children[0].stringValue == "org.freedesktop.appearance",
            let key = children[1].stringValue
        else { return nil }
        return (key, children[2])
    }

    private static func unwrapped(_ value: DBusValue) -> DBusValue {
        switch value {
        case .variant(let nested): return unwrapped(nested)
        case .tuple(let values) where values.count == 1: return unwrapped(values[0])
        default: return value
        }
    }
}
