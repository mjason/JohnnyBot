#if os(macOS)
import AppKit
import ScreenCaptureKit

@MainActor
final class ComposerScreenshot: NSObject, SCContentSharingPickerObserver {
    static let shared = ComposerScreenshot()

    private var completion: ((Result<ACPAttachment?, Error>) -> Void)?

    func take(_ completion: @escaping (Result<ACPAttachment?, Error>) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in finish(.success(nil)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard completion != nil else { return }
            do {
                let configuration = SCStreamConfiguration()
                let size = filter.contentRect.size
                let scale = min(CGFloat(filter.pointPixelScale), 2048 / max(1, size.width, size.height))
                configuration.width = max(1, Int(size.width * scale))
                configuration.height = max(1, Int(size.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let attachment = try await Task.detached { try ACPAttachment.imageAttachment(image, name: "截图") }.value
                finish(.success(attachment))
            } catch {
                finish(.failure(error))
            }
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in finish(.failure(error)) }
    }

    private func finish(_ result: Result<ACPAttachment?, Error>) {
        guard let completion else { return }
        self.completion = nil
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        completion(result)
    }
}
#endif
