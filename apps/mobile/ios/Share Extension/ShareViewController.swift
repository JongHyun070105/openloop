import UIKit
import MobileCoreServices
import UniformTypeIdentifiers
import UserNotifications

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var appGroupId: String = "group.com.openloop.openloop_mobile"
    private var sharedMedia: [SharedMediaFile] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        loadAppGroupId()
        processSharedItems()
    }

    private func loadAppGroupId() {
        if let customAppGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String, !customAppGroupId.isEmpty {
            appGroupId = customAppGroupId
        }
    }

    private func processSharedItems() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], !items.isEmpty else {
            completeExtension()
            return
        }

        let dispatchGroup = DispatchGroup()

        for item in items {
            guard let attachments = item.attachments else { continue }
            for attachment in attachments {
                for type in SharedMediaType.allCases {
                    if attachment.hasItemConformingToTypeIdentifier(type.toUTTypeIdentifier) {
                        dispatchGroup.enter()
                        attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier, options: nil) { [weak self] data, error in
                            defer { dispatchGroup.leave() }
                            guard let self = self, error == nil else { return }
                            self.handleAttachment(data: data, type: type)
                        }
                        break
                    }
                }
            }
        }

        dispatchGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.saveSharedMediaAndNotify()
        }
    }

    private func handleAttachment(data: NSSecureCoding?, type: SharedMediaType) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return
        }

        switch type {
        case .text:
            if let text = data as? String {
                sharedMedia.append(SharedMediaFile(path: text, mimeType: "text/plain", type: .text))
            } else if let url = data as? URL {
                sharedMedia.append(SharedMediaFile(path: url.absoluteString, mimeType: "text/plain", type: .text))
            }
        case .url:
            if let url = data as? URL {
                sharedMedia.append(SharedMediaFile(path: url.absoluteString, mimeType: "text/plain", type: .url))
            } else if let text = data as? String {
                sharedMedia.append(SharedMediaFile(path: text, mimeType: "text/plain", type: .url))
            }
        case .image:
            let fileName = "\(UUID().uuidString).png"
            let dstURL = containerURL.appendingPathComponent(fileName)

            if let url = data as? URL {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }

                if copyFile(at: url, to: dstURL) {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                } else if let fileData = try? Data(contentsOf: url), (try? fileData.write(to: dstURL)) != nil {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                } else if let image = UIImage(contentsOfFile: url.path), let pngData = image.pngData(), (try? pngData.write(to: dstURL)) != nil {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                }
            } else if let image = data as? UIImage {
                if let pngData = image.pngData(), (try? pngData.write(to: dstURL)) != nil {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                }
            } else if let rawData = data as? Data {
                if (try? rawData.write(to: dstURL)) != nil {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                } else if let image = UIImage(data: rawData), let pngData = image.pngData(), (try? pngData.write(to: dstURL)) != nil {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: "image/png", type: .image))
                }
            }
        default:
            if let url = data as? URL {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
                let fileName = UUID().uuidString + "_" + url.lastPathComponent
                let dstURL = containerURL.appendingPathComponent(fileName)
                if copyFile(at: url, to: dstURL) {
                    sharedMedia.append(SharedMediaFile(path: dstURL.path, mimeType: nil, type: type))
                }
            }
        }
    }

    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            return true
        } catch {
            return false
        }
    }

    private func saveSharedMediaAndNotify() {
        guard !sharedMedia.isEmpty else {
            completeExtension()
            return
        }

        let userDefaults = UserDefaults(suiteName: appGroupId)
        if let encoded = try? JSONEncoder().encode(sharedMedia) {
            userDefaults?.set(encoded, forKey: kUserDefaultsKey)
            userDefaults?.synchronize()
        }

        sendNotificationAndComplete()
    }

    private func sendNotificationAndComplete() {
        let content = UNMutableNotificationContent()
        content.title = "🎯 OpenLoop에 공유되었습니다"
        content.body = "AI 비서가 분석을 준비합니다.\n탭하여 분석 결과를 확인하고 정리하세요."
        content.sound = .default
        content.userInfo = ["payload": "share:pending"]

        let request = UNNotificationRequest(
            identifier: "openloop_share_\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.2, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { [weak self] _ in
            DispatchQueue.main.async {
                self?.completeExtension()
            }
        }
    }

    private func completeExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
