import Foundation
import Testing

@testable import SkrepkaLinuxPlatform

/// Telling avahi refusing to publish at all — SteamOS's stock configuration —
/// from avahi refusing one record, which is what decides whether skrepkad
/// publishes by itself.
@Suite("avahi publishing refusals")
struct AvahiPublishingRefusalTests {
    static let notPermitted = "org.freedesktop.Avahi.NotPermittedError"

    @Test("NotPermitted on EntryGroupNew or AddService is a refusal to publish")
    func recognisesBothRefusals() {
        for method in ["EntryGroupNew", "AddService"] {
            let error = AvahiError.refused(method: method, name: Self.notPermitted, detail: "Not permitted")
            #expect(AvahiDiscovery.isPublishingRefusal(error))
        }
    }

    @Test("any other refusal is not")
    func ignoresOtherRefusals() {
        let collision = AvahiError.refused(
            method: "AddService", name: "org.freedesktop.Avahi.CollisionError", detail: "")
        #expect(!AvahiDiscovery.isPublishingRefusal(collision))
        let elsewhere = AvahiError.refused(method: "ServiceBrowserNew", name: Self.notPermitted, detail: "")
        #expect(!AvahiDiscovery.isPublishingRefusal(elsewhere))
        #expect(!AvahiDiscovery.isPublishingRefusal(AvahiError.noReply(method: "EntryGroupNew")))
    }

    @Test("the message names the setting that refused, and SteamOS")
    func namesTheSetting() {
        let userServices = AvahiError.refused(method: "EntryGroupNew", name: Self.notPermitted, detail: "")
        #expect(userServices.description.contains("disable-user-service-publishing=yes"))
        #expect(userServices.description.contains("SteamOS"))
        let everything = AvahiError.refused(method: "AddService", name: Self.notPermitted, detail: "")
        #expect(everything.description.contains("`disable-publishing=yes`"))
        #expect(everything.description.contains("sudo systemctl restart avahi-daemon"))
    }
}
