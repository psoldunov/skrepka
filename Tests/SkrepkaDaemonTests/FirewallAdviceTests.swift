import Foundation
import SkrepkaIPC
import Testing

/// Which firewall a distribution ships, and the command that opens Skrepka's
/// ports in it.
@Suite("Firewall advice")
struct FirewallAdviceTests {
    @Test(
        "os-release names the firewall front-end",
        arguments: [
            ("ID=nixos\nNAME=NixOS\n", FirewallAdvice.Family.nixos),
            ("NAME=\"Fedora Linux\"\nID=fedora\n", .firewalld),
            ("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n", .firewalld),
            ("ID=ubuntu\nID_LIKE=debian\n", .ufw),
            // A derivative is known by what it is like.
            ("ID=pop\nID_LIKE=\"ubuntu debian\"\n", .ufw),
            // SteamOS ships no firewall at all; nothing to name.
            ("ID=steamos\nID_LIKE=arch\n", .unknown),
            ("", .unknown),
        ]
    )
    func readsTheFamily(_ text: String, _ family: FirewallAdvice.Family) {
        #expect(FirewallAdvice(osRelease: text).family == family)
    }

    @Test("Ports are named as a range when they are one")
    func describesPorts() {
        #expect(FirewallAdvice.describe([27182, 27183]) == "TCP ports 27182–27183")
        #expect(FirewallAdvice.describe([41705]) == "TCP port 41705")
        #expect(FirewallAdvice.describe([27183, 41705]) == "TCP ports 27183 and 41705")
    }

    /// The module option opens Skrepka's own pair and nothing else, so it is
    /// only the answer when those are the ports in question.
    @Test("NixOS is pointed at openFirewall only for Skrepka's own ports")
    func nixosRemedy() {
        let nixos = FirewallAdvice(family: .nixos)
        #expect(nixos.remedy(opening: SkrepkaPorts.all).contains("programs.skrepka.openFirewall = true;"))

        let moved = nixos.remedy(opening: [27183, 41705])
        #expect(!moved.contains("openFirewall"))
        #expect(moved.contains("allowedTCPPorts = [ 27183 41705 ]"))
    }

    @Test("firewalld and ufw get their own range syntax")
    func rangeSyntax() {
        let firewalld = FirewallAdvice(family: .firewalld).remedy(opening: SkrepkaPorts.all)
        #expect(firewalld.contains("--add-port=27182-27183/tcp"))
        #expect(firewalld.contains("--add-service=mdns"))

        let ufw = FirewallAdvice(family: .ufw).remedy(opening: SkrepkaPorts.all)
        #expect(ufw.contains("sudo ufw allow proto tcp from any to any port 27182:27183"))
        #expect(ufw.contains("sudo ufw allow 5353/udp"))
    }
}
