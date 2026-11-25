import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

nonisolated struct ACPAttachment: Identifiable, Sendable {
    nonisolated struct Preview: Identifiable, Sendable {
        let id = UUID()
        let name: String
        var isImage = false
        var thumbnail: Data?
        var fileURL: URL?
    }

    static let maxFileBytes = 92 * 1024
    static let maxTotalBytes = 92 * 1024
    private static let maxImageSourceBytes = 32 * 1024 * 1024
    private static let resourceScheme = "johnny-attachment"

    private enum Content {
        case image(Data)
        case text(String)
        case binary(Data)
    }

    let preview: Preview
    private let mimeType: String
    private let content: Content
    var id: UUID { preview.id }

    var byteCount: Int {
        switch content {
        case .image(let data), .binary(let data): data.count
        case .text(let text): text.utf8.count
        }
    }

    var promptBlock: [String: Any] {
        if case .image(let data) = content {
            return ["type": "image", "mimeType": mimeType, "data": data.base64EncodedString(),
                    "_meta": ["johnny/attachment_name": preview.name, "johnny/attachment_id": id.uuidString]]
        }
        let uri = Self.resourceBaseURL.appending(component: id.uuidString)
            .appending(component: preview.name).absoluteString
        var resource: [String: Any] = ["uri": uri, "mimeType": mimeType]
        switch content {
        case .text(let text): resource["text"] = text
        case .binary(let data): resource["blob"] = data.base64EncodedString()
        case .image: break
        }
        return ["type": "resource", "resource": resource]
    }

    static func file(at url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw AttachmentError.fileRequired }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let limit = type.conforms(to: .image) ? maxImageSourceBytes : maxFileBytes
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AttachmentError.tooLarge(limit) }
        let name = url.lastPathComponent
        if type.conforms(to: .image) { return try image(data, name: name) }

        var preview = Preview(name: name)
        preview.fileURL = AttachmentPreviewCache.store(data, name: name, id: preview.id)
        let mimeType = type.preferredMIMEType ?? "application/octet-stream"
        if type.conforms(to: .pdf), let text = PDFDocument(data: data)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= maxFileBytes {
            return Self(preview: preview, mimeType: "text/plain", content: .text(text))
        }
        // Source files often have a dynamic UTI. Validate the bytes before treating them as text.
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            return Self(preview: preview, mimeType: type.conforms(to: .text) ? mimeType : "text/plain",
                        content: .text(text))
        }
        return Self(preview: preview, mimeType: mimeType, content: .binary(data))
    }

    static func image(_ data: Data, name: String) throws -> Self {
        guard data.count <= maxImageSourceBytes else { throw AttachmentError.tooLarge(maxImageSourceBytes) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = resizedImage(source, maxPixels: 2048) else { throw AttachmentError.invalidImage }
        let mimeType = CGImageSourceGetType(source).flatMap { UTType($0 as String)?.preferredMIMEType }
        let original = (data, AttachmentPreviewCache.typedName(name, mimeType: mimeType))
        return try imageAttachment(image, name: name, original: original)
    }

    static func imageAttachment(_ image: CGImage, name: String, original: (data: Data, name: String)? = nil) throws -> Self {
        guard let png = encode(image, type: .png) else { throw AttachmentError.invalidImage }
        if png.count <= maxFileBytes {
            return makeImage(png, mimeType: "image/png", name: name, original: original)
        }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { throw AttachmentError.invalidImage }
        for size in [1440, 1080, 800, 600, 400, 256] {
            if let scaled = resizedImage(source, maxPixels: size), let jpeg = encode(scaled, type: .jpeg),
               jpeg.count <= maxFileBytes {
                return makeImage(jpeg, mimeType: "image/jpeg", name: name, original: original)
            }
        }
        throw AttachmentError.tooLarge(maxFileBytes)
    }

    private static func makeImage(_ data: Data, mimeType: String, name: String, original: (data: Data, name: String)?) -> Self {
        var preview = Preview(name: name, isImage: true, thumbnail: thumbnail(data))
        let filename = original?.name ?? AttachmentPreviewCache.typedName(name, mimeType: mimeType)
        preview.fileURL = AttachmentPreviewCache.store(original?.data ?? data, name: filename, id: preview.id)
        return Self(preview: preview, mimeType: mimeType, content: .image(data))
    }

    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = resizedImage(source, maxPixels: 360) else { return nil }
        return encode(image, type: .png)
    }

    private static func resizedImage(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.87] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func replayPreview(_ block: [String: Any]) -> Preview? {
        switch block["type"] as? String {
        case "image":
            let meta = block["_meta"] as? [String: Any]
            let name = (meta?["johnny/attachment_name"] as? String)
                ?? (block["uri"] as? String).flatMap(URL.init(string:))?.lastPathComponent
            let id = (meta?["johnny/attachment_id"] as? String).flatMap(UUID.init(uuidString:))
            return imagePreview(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "图片",
                                mimeType: block["mimeType"] as? String, base64: block["data"] as? String, id: id)
        case "resource_link":
            guard let name = block["name"] as? String else { return nil }
            let uri = (block["uri"] as? String).flatMap(URL.init(string:))
            return Preview(name: name, fileURL: uri.flatMap(cachedOriginal))
        case "resource":
            guard let resource = block["resource"] as? [String: Any],
                  let rawURI = resource["uri"] as? String, let uri = URL(string: rawURI) else { return nil }
            let name = uri.lastPathComponent.isEmpty ? "文件" : uri.lastPathComponent
            let mimeType = resource["mimeType"] as? String
            let blob = resource["blob"] as? String
            if mimeType?.hasPrefix("image/") == true {
                return imagePreview(name: name, mimeType: mimeType, base64: blob, id: resourceID(uri))
            }
            return resourcePreview(uri: uri, text: resource["text"] as? String, blob: blob, mimeType: mimeType)
        case "text":
            // Codex replays images and embedded resources as text in ACP v1.
            guard let text = block["text"] as? String else { return nil }
            if text.hasPrefix("[@image](data:image/"), text.hasSuffix(")"),
               let separator = text.range(of: ";base64,") {
                let mimeType = String(text[text.index(text.startIndex, offsetBy: "[@image](data:".count)..<separator.lowerBound])
                let base64 = text[separator.upperBound..<text.index(before: text.endIndex)]
                return imagePreview(name: "图片", mimeType: mimeType, base64: String(base64))
            }
            return replayedTextResource(text)
        default:
            return nil
        }
    }

    private static func imagePreview(name: String, mimeType: String?, base64: String?, id: UUID? = nil) -> Preview {
        let filename = AttachmentPreviewCache.typedName(name, mimeType: mimeType ?? "image/png")
        let data = decodeBlob(base64)
        let thumbnail = data.flatMap(thumbnail)
        let fileURL = id.flatMap { AttachmentPreviewCache.original(name: filename, id: $0) }
            ?? data.flatMap { thumbnail == nil ? nil : AttachmentPreviewCache.store($0, name: filename) }
        return Preview(name: name, isImage: true, thumbnail: thumbnail, fileURL: fileURL)
    }

    private static func replayedTextResource(_ content: String) -> Preview? {
        guard content.hasPrefix("\(resourceScheme)://local/"), let firstLine = content.firstIndex(of: "\n"),
              let uri = URL(string: String(content[..<firstLine])), resourceID(uri) != nil else { return nil }
        let context = content[content.index(after: firstLine)...]
        let closing = "\n</context>"
        guard let headerEnd = context.firstIndex(of: "\n"), context.hasSuffix(closing) else { return nil }
        let header = context[..<headerEnd]
        guard header.hasPrefix("<context ref=\"\(content[..<firstLine])\""), header.hasSuffix(">") else { return nil }
        let payload = context[context.index(after: headerEnd)...].dropLast(closing.count)
        if header.hasSuffix(" encoding=\"base64\">") {
            return resourcePreview(uri: uri, text: nil, blob: String(payload), mimeType: nil)
        }
        return resourcePreview(uri: uri, text: String(payload), blob: nil, mimeType: nil)
    }

    private static func resourcePreview(uri: URL, text: String?, blob: String?, mimeType: String?) -> Preview {
        let name = uri.lastPathComponent.isEmpty ? "文件" : uri.lastPathComponent
        if let fileURL = cachedOriginal(uri) { return Preview(name: name, fileURL: fileURL) }
        if let text, text.utf8.count <= maxFileBytes {
            return Preview(name: name, fileURL: AttachmentPreviewCache.store(Data(text.utf8), name: AttachmentPreviewCache.textName(name)))
        }
        let filename = AttachmentPreviewCache.typedName(name, mimeType: mimeType)
        let fileURL = decodeBlob(blob).flatMap { AttachmentPreviewCache.store($0, name: filename) }
        return Preview(name: name, fileURL: fileURL)
    }

    private static func decodeBlob(_ base64: String?) -> Data? {
        guard let base64, base64.utf8.count <= maxFileBytes * 2,
              let data = Data(base64Encoded: base64), data.count <= maxFileBytes else { return nil }
        return data
    }

    private static func cachedOriginal(_ uri: URL) -> URL? {
        resourceID(uri).flatMap { AttachmentPreviewCache.original(name: uri.lastPathComponent, id: $0) }
    }

    private static func resourceID(_ uri: URL) -> UUID? {
        let components = uri.pathComponents
        guard uri.scheme == resourceScheme, uri.host == "local", components.count == 3 else { return nil }
        return UUID(uuidString: components[1])
    }

    private static let resourceBaseURL = URL(string: "\(resourceScheme)://local/")!
}

nonisolated enum AttachmentError: LocalizedError {
    case fileRequired, invalidImage, unsupportedImage, unsupportedFile, tooLarge(Int), messageTooLarge

    var errorDescription: String? {
        switch self {
        case .fileRequired: "请选择文件。"
        case .invalidImage: "无法读取这张图片。"
        case .unsupportedImage: "当前 Agent 不支持图片附件。"
        case .unsupportedFile: "当前 Agent 不支持文件附件。"
        case .tooLarge(let bytes): "附件超过 \(bytes / 1024) KiB。"
        case .messageTooLarge: "这条消息的附件太大，请移除部分附件后重试。"
        }
    }
}
