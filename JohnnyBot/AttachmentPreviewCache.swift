import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated enum AttachmentPreviewCache {
    static func store(_ data: Data, name: String, id: UUID? = nil) -> URL? {
        let directoryName = id?.uuidString ?? Data(SHA256.hash(data: data)).base64URLEncodedString()
        let url = fileURL(name: name, directory: directoryName)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            return nil
        }
    }

    static func original(name: String, id: UUID) -> URL? {
        let url = fileURL(name: name, directory: id.uuidString)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func textName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.conforms(to: .text) == true ? name : name + ".txt"
    }

    static func typedName(_ name: String, mimeType: String?) -> String {
        guard (name as NSString).pathExtension.isEmpty,
              let ext = mimeType.flatMap({ UTType(mimeType: $0)?.preferredFilenameExtension }) else { return name }
        return name + "." + ext
    }

    private static func fileURL(name: String, directory: String) -> URL {
        let root = URL.cachesDirectory.appending(path: "ACPAttachmentPreviews", directoryHint: .isDirectory)
        let validName = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\0", with: "_")
        let ext = (validName as NSString).pathExtension
        let stem = (validName as NSString).deletingPathExtension
        // Keep the extension Quick Look needs even after truncating a very long label.
        let base = String(stem.prefix(46))
        let safeName = base.isEmpty || base == "." || base == ".." ? "附件" : base
        let filename = ext.isEmpty ? safeName : safeName + "." + String(ext.prefix(16))
        return root.appending(path: directory, directoryHint: .isDirectory).appending(component: filename)
    }
}

private extension Data {
    nonisolated func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }
}
