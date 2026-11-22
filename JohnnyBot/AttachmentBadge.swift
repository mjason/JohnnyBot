import QuickLook
import SwiftUI

struct AttachmentBadge: View {
    let preview: ACPAttachment.Preview
    var remove: (() -> Void)?
    @State private var quickLookURL: URL?
    @State private var previewUnavailable = false

    var body: some View {
        HStack(spacing: 0) {
            if let url = preview.fileURL {
                Button {
                    if FileManager.default.isReadableFile(atPath: url.path) { quickLookURL = url }
                    else { previewUnavailable = true }
                } label: {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("快速查看 \(preview.name)")
                .help("快速查看 \(preview.name)")
            } else {
                label.help("附件未提供可预览的内容")
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 \(preview.name)")
                .help("移除附件")
            }
        }
        .fixedSize()
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .quickLookPreview($quickLookURL)
        .alert("无法预览附件", isPresented: $previewUnavailable) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("本机的附件副本已不可用。")
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            thumbnail
            Text(preview.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.leading, 6)
        .padding(.trailing, remove == nil ? 9 : 4)
        .padding(.vertical, 4)
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            image.resizable()
                .scaledToFill()
                .frame(width: 34, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: preview.isImage ? "photo" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 25, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var image: Image? {
        guard let data = preview.thumbnail else { return nil }
#if os(macOS)
        return NSImage(data: data).map(Image.init(nsImage:))
#else
        return UIImage(data: data).map(Image.init(uiImage:))
#endif
    }
}
