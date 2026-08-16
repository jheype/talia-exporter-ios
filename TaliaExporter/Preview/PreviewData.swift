import Foundation

enum PreviewData {
    static let user = TaliaUser(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        email: "joao@taliaai.com",
        role: "team_member",
        isOwner: false
    )

    static let session = ExporterSession(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        userID: user.id,
        phoneNumber: "+44 •••• 1842",
        status: .connected,
        captureEnabled: true,
        includeMedia: true,
        linkedAt: Date().addingTimeInterval(-86_400),
        lastConnectedAt: Date(),
        lastMessageAt: Date().addingTimeInterval(-18),
        lastSynchronisedAt: Date().addingTimeInterval(-4),
        lastError: nil,
        selectedGroupCount: 12,
        capturedMessageCount: 4_218
    )

    static let groups: [ExportGroup] = [
        .init(id: "120363001@g.us", name: "Project Phoenix", participantCount: 28, isSelected: true, lastMessageAt: Date()),
        .init(id: "120363002@g.us", name: "Logistics Updates", participantCount: 14, isSelected: true, lastMessageAt: Date().addingTimeInterval(-120)),
        .init(id: "120363003@g.us", name: "London Dealers", participantCount: 62, isSelected: true, lastMessageAt: Date().addingTimeInterval(-240)),
        .init(id: "120363004@g.us", name: "Global Sourcing", participantCount: 31, isSelected: true, lastMessageAt: Date().addingTimeInterval(-420)),
        .init(id: "120363005@g.us", name: "NYC Showroom", participantCount: 12, isSelected: true, lastMessageAt: Date().addingTimeInterval(-720)),
        .init(id: "120363006@g.us", name: "Client Concierge", participantCount: 19, isSelected: true, lastMessageAt: Date().addingTimeInterval(-1_080)),
        .init(id: "120363007@g.us", name: "Rolex UK Trade", participantCount: 87, isSelected: true, lastMessageAt: Date().addingTimeInterval(-1_380)),
        .init(id: "120363008@g.us", name: "AP & Patek Europe", participantCount: 46, isSelected: true, lastMessageAt: Date().addingTimeInterval(-1_860)),
        .init(id: "120363009@g.us", name: "Dubai Dealers", participantCount: 53, isSelected: false, lastMessageAt: Date().addingTimeInterval(-86_400))
    ]

    static let events: [CaptureEvent] = [
        .init(id: UUID(), groupName: "Project Phoenix", detail: "152 messages captured", createdAt: Date(), kind: .captured),
        .init(id: UUID(), groupName: "Logistics Updates", detail: "87 messages captured", createdAt: Date().addingTimeInterval(-120), kind: .captured),
        .init(id: UUID(), groupName: "Global Sourcing", detail: "Session synchronised", createdAt: Date().addingTimeInterval(-420), kind: .synchronised)
    ]

    static let messages: [CapturedMessage] = [
        .init(id: UUID(), whatsappMessageID: "A1", groupJID: groups[0].id, groupName: groups[0].name, senderJID: "1@s.whatsapp.net", sender: "James", body: "126500LN white dial, 2025 full set — £26,800", type: .text, timestamp: Date(), isFromMe: false, hasMedia: false, isEdited: false, isRevoked: false, revision: 1, mediaMetadata: nil),
        .init(id: UUID(), whatsappMessageID: "A2", groupJID: groups[0].id, groupName: groups[0].name, senderJID: "2@s.whatsapp.net", sender: "Harry", body: "Can collect in London this afternoon.", type: .text, timestamp: Date().addingTimeInterval(-60), isFromMe: false, hasMedia: false, isEdited: false, isRevoked: false, revision: 1, mediaMetadata: nil),
        .init(id: UUID(), whatsappMessageID: "A3", groupJID: groups[1].id, groupName: groups[1].name, senderJID: "3@s.whatsapp.net", sender: "Sophie", body: "The Geneva shipment has cleared customs.", type: .text, timestamp: Date().addingTimeInterval(-120), isFromMe: false, hasMedia: false, isEdited: false, isRevoked: false, revision: 1, mediaMetadata: nil)
    ]
}
