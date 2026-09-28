import Foundation

/// How to let other devices reach Skrepka through this machine's firewall.
///
/// A daemon without root cannot read the rules, and must not try to change
/// them, so it cannot know whether a firewall is in the way — only notice the
/// symptom, and say what to do in the words this distribution uses. The
/// family comes from `/etc/os-release`'s `ID` and `ID_LIKE` (os-release(5)),
/// because the firewall front-end is a distribution default rather than
/// something a process can ask about.
///
/// Commands checked against the firewall-cmd(1) and ufw(8) manual pages:
/// `--add-port=portid[-portid]/protocol` and `--add-service=service` may each
/// repeat, and ufw takes a range as `start:end` with the protocol required.
public struct FirewallAdvice: Sendable, Hashable {
    public enum Family: Sendable, Hashable {
        /// NixOS: the firewall is on and dropping unless configured otherwise,
        /// and the configuration is declarative, so the remedy is an option.
        case nixos
        /// Fedora and its relatives: firewalld.
        case firewalld
        /// Debian, Ubuntu and their relatives: ufw, when it is enabled at all.
        case ufw
        case unknown
    }

    public let family: Family

    public init(family: Family) {
        self.family = family
    }

    /// The family `/etc/os-release` describes, or ``Family/unknown`` for text
    /// that names none this knows.
    public init(osRelease text: String) {
        let names = Self.value(of: "ID", in: text).union(Self.value(of: "ID_LIKE", in: text))
        if names.contains("nixos") {
            family = .nixos
        } else if !names.isDisjoint(with: ["fedora", "rhel", "centos", "opensuse", "suse"]) {
            family = .firewalld
        } else if !names.isDisjoint(with: ["debian", "ubuntu"]) {
            family = .ufw
        } else {
            family = .unknown
        }
    }

    /// This machine's, read from `/etc/os-release` and then from
    /// `/usr/lib/os-release`, the fallback os-release(5) names.
    public static func current() -> FirewallAdvice {
        for path in ["/etc/os-release", "/usr/lib/os-release"] {
            // An unreadable file is not an error worth reporting: it only means
            // the advice is the generic sentence rather than a command.
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                return FirewallAdvice(osRelease: text)
            }
        }
        return FirewallAdvice(family: .unknown)
    }

    /// "TCP ports 27182–27183", or the ports one by one when they are not a
    /// range. `ports` is what other devices dial, lowest first.
    public static func describe(_ ports: [Int]) -> String {
        guard let range = PortRange(ports) else {
            let list = ports.map(String.init).joined(separator: " and ")
            return ports.count == 1 ? "TCP port \(list)" : "TCP ports \(list)"
        }
        return "TCP ports \(range.lower)–\(range.upper)"
    }

    /// One sentence saying how to open `ports`, and UDP 5353 for discovery,
    /// on this machine.
    ///
    /// On NixOS the module's `openFirewall` is the answer only for Skrepka's
    /// own pair, ``SkrepkaPorts/all``, because that is all it opens.
    public func remedy(opening ports: [Int]) -> String {
        switch family {
        case .nixos where ports == SkrepkaPorts.all:
            return """
                On NixOS, set `programs.skrepka.openFirewall = true;` in the system \
                configuration and rebuild.
                """
        case .nixos:
            let list = ports.map(String.init).joined(separator: " ")
            return """
                On NixOS, add `networking.firewall.allowedTCPPorts = [ \(list) ];` and \
                `networking.firewall.allowedUDPPorts = [ 5353 ];` to the system configuration \
                and rebuild.
                """
        case .firewalld:
            let adds = Self.specs(ports, rangeSeparator: "-").map { "--add-port=\($0)/tcp" }
            return """
                With firewalld: `sudo firewall-cmd --permanent \(adds.joined(separator: " "))`, \
                `sudo firewall-cmd --permanent --add-service=mdns`, then \
                `sudo firewall-cmd --reload`.
                """
        case .ufw:
            let list = Self.specs(ports, rangeSeparator: ":").joined(separator: ",")
            return """
                With ufw: `sudo ufw allow proto tcp from any to any port \(list)` and \
                `sudo ufw allow 5353/udp`.
                """
        case .unknown:
            return "Allow them, and UDP 5353 for discovery, in whichever firewall this machine runs."
        }
    }

    /// Ports as firewall specs: one range when they are consecutive, else one
    /// spec each.
    private static func specs(_ ports: [Int], rangeSeparator: String) -> [String] {
        guard let range = PortRange(ports) else { return ports.map(String.init) }
        return ["\(range.lower)\(rangeSeparator)\(range.upper)"]
    }

    /// Every value of `key`, split on spaces — `ID_LIKE` is a list.
    private static func value(of key: String, in text: String) -> Set<String> {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            return Set(value.lowercased().split(separator: " ").map(String.init))
        }
        return []
    }
}

/// Two consecutive ports, which every firewall front-end can write as one
/// range.
private struct PortRange {
    let lower: Int
    let upper: Int

    init?(_ ports: [Int]) {
        guard ports.count == 2, ports[1] == ports[0] + 1 else { return nil }
        lower = ports[0]
        upper = ports[1]
    }
}
