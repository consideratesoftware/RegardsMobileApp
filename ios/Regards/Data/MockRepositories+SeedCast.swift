import Foundation

// The Star Wars sample-cast fixture — split out of `MockRepositories.swift`
// to keep that file under the lint length limit. Pure fixture data, no
// logic; kept next to `MockStore` conceptually via this same-module
// extension.
extension MockStore {
    static func seedCast(
        now: Date,
        includeDuplicateFixture: Bool
    ) -> [Contact] {
        let day: TimeInterval = 86_400
        var contacts = [
            Contact(
                systemContactRef: "sys-leia",
                displayName: "Leia Organa",
                tracked: true, cadenceDays: 14,
                priorityTier: .innerCircle,
                preferredChannel: .whatsapp,
                preferredChannelValue: "+1 415 555 0140",
                lastInteractedAt: now.addingTimeInterval(-day * 23),
                notes: "Son is Ben. Ask about the diplomatic posting on Chandrila."),
            Contact(
                systemContactRef: "sys-padme",
                displayName: "Padmé Amidala",
                tracked: true, cadenceDays: 7,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0134",
                lastInteractedAt: now.addingTimeInterval(-day * 11)),
            Contact(
                systemContactRef: "sys-luke",
                displayName: "Luke Skywalker",
                tracked: true, cadenceDays: 30,
                priorityTier: .close,
                preferredChannel: .signal,
                preferredChannelValue: "+1 415 555 0198",
                lastInteractedAt: now.addingTimeInterval(-day * 36)),
            Contact(
                systemContactRef: "sys-lando",
                displayName: "Lando Calrissian",
                tracked: true, cadenceDays: 21,
                priorityTier: .close,
                preferredChannel: .sms,
                preferredChannelValue: "+1 212 555 0176",
                lastInteractedAt: now.addingTimeInterval(-day * 23)),
            Contact(
                systemContactRef: "sys-chewbacca",
                displayName: "Chewbacca",
                tracked: true, cadenceDays: 30,
                priorityTier: .regular,
                preferredChannel: .whatsapp,
                preferredChannelValue: "+1 415 555 0141",
                lastInteractedAt: now.addingTimeInterval(-day * 28)),
            Contact(
                systemContactRef: "sys-anakin",
                displayName: "Anakin Skywalker",
                tracked: true, cadenceDays: 14,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0177",
                lastInteractedAt: now.addingTimeInterval(-day * 8)),
            Contact(
                systemContactRef: "sys-din",
                displayName: "Din Djarin",
                tracked: true, cadenceDays: 42,
                priorityTier: .regular,
                preferredChannel: .signal,
                preferredChannelValue: "+1 415 555 0142",
                lastInteractedAt: now.addingTimeInterval(-day * 42)),
            Contact(
                systemContactRef: "sys-shmi",
                displayName: "Shmi Skywalker",
                tracked: true, cadenceDays: 10,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0111",
                lastInteractedAt: now.addingTimeInterval(-day * 2)),
            Contact(
                systemContactRef: "sys-obiwan",
                displayName: "Obi-Wan Kenobi",
                tracked: true, cadenceDays: 90,
                priorityTier: .regular,
                preferredChannel: .email,
                preferredChannelValue: "obiwan@jeditemple.example",
                lastInteractedAt: now.addingTimeInterval(-day * 84)),
            Contact(
                systemContactRef: "sys-ahsoka",
                displayName: "Ahsoka Tano",
                tracked: true, cadenceDays: 90,
                priorityTier: .close,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0143",
                lastInteractedAt: now.addingTimeInterval(-day * 87)),
        ]
        if includeDuplicateFixture {
            contacts.append(Contact(
                systemContactRef: "ui-test-luke-duplicate",
                displayName: "Luke Skywalker",
                tracked: true,
                cadenceDays: 30,
                priorityTier: .close,
                preferredChannel: .signal,
                preferredChannelValue: "+1 415 555 0198",
                lastInteractedAt: now.addingTimeInterval(-day * 36)
            ))
        }
        return contacts
    }
}
