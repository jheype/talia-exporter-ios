import SwiftUI
import ImageIO

struct WorkspaceMediaView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let media: WorkMedia
    var isIdea = false
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Button { attempt += 1 } label: { Label("Retry image", systemImage: "arrow.clockwise") }
                    .font(.caption).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: "\(store.ownerID?.uuidString ?? "")-\(media.id)-\(isIdea)-\(attempt)") {
            image = nil
            failed = false
            guard let api = store.api, let owner = store.ownerID else { return }
            do {
                let access = try await api.imageAccess(media.id, isIdea: isIdea)
                let data = try await WorkspaceImageIO.download(access.url)
                try Task.checkCancellation()
                guard owner == store.ownerID else { return }
                image = UIImage(data: data)
                failed = image == nil
            } catch {
                if !Task.isCancelled, owner == store.ownerID { failed = true }
            }
        }
        .accessibilityLabel(isIdea ? "Idea image" : "Attached message image")
    }
}

/// Image bytes are transient. The download session has no authentication cookies,
/// shared URL cache or persistent storage; only the API issues authorised image URLs.
actor WorkspaceImageIO {
    static func download(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true, data.count <= 8 * 1024 * 1024 else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    static func prepareJPEG(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard data.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1800,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else {
                throw APIError(statusCode: nil, code: "CLIENT.INVALID_IMAGE", message: "This image could not be opened. Choose another photo.")
            }
            return jpeg
        }.value
    }
}

struct WorkMessageCard: View {
    let message: WorkMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                GroupAvatar(initials: message.senderName.workInitials, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.senderName).font(.subheadline.weight(.semibold))
                    Text(message.groupName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(message.occurredAt, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.body.isEmpty { Text(message.body).font(.body).textSelection(.enabled) }
            ForEach(message.media) { media in
                WorkspaceMediaView(media: media).frame(maxHeight: 200)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).taliaCard()
    }
}

extension String {
    var workInitials: String {
        split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

