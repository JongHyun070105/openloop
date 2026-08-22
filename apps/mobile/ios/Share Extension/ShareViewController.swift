import UniformTypeIdentifiers
import UIKit
import UserNotifications

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let defaultAppGroupId = "group.com.openloop.openloop_mobile"
    private let defaultAPIBaseURL = "https://mrodt7pxq4.execute-api.ap-northeast-2.amazonaws.com/dev"
    private let pipelineStatusKey = "share_pipeline_status_v1"
    private let installationIdKey = "openloop_installation_id_v1"
    private let apiBaseURLKey = "openloop_api_base_url_v1"
    private let jobKeyPrefix = "background_analysis_job_v1."
    private let sessionPrefix = "com.openloop.openloopMobile.share-analysis."

    private var appGroupId = "group.com.openloop.openloop_mobile"
    private var backgroundSession: URLSession?
    private var backgroundDelegate: ShareBackgroundAnalysisDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        appGroupId = (Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? defaultAppGroupId
        loadSharedItem()
    }

    private func loadSharedItem() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finishWithQueueFailure("공유된 항목을 읽지 못했습니다.")
            return
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            loadImage(from: provider)
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }) {
            loadText(from: provider, typeIdentifier: UTType.text.identifier)
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            loadText(from: provider, typeIdentifier: UTType.url.identifier)
        } else {
            finishWithQueueFailure("지원하는 이미지나 텍스트가 없습니다.")
        }
    }

    private func loadImage(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            do {
                if let error { throw error }
                let image = try self.decodeImage(item)
                guard let jpeg = image.jpegData(compressionQuality: 0.92) else {
                    throw ShareQueueError.imageEncoding
                }
                guard jpeg.count <= 10 * 1024 * 1024 else {
                    throw ShareQueueError.imageTooLarge
                }
                let fallbackURL = try self.writeSharedFile(
                    data: jpeg,
                    name: "openloop-share-\(UUID().uuidString).jpg"
                )
                self.saveFallbackCapture([
                    SharedMediaFile(path: fallbackURL.path, mimeType: "image/jpeg", type: .image)
                ])
                try self.enqueueBackgroundAnalysis(imageData: jpeg, text: "", fallbackURL: fallbackURL)
            } catch {
                self.finishWithQueueFailure(error.localizedDescription)
            }
        }
    }

    private func loadText(from provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, error in
            guard let self else { return }
            do {
                if let error { throw error }
                let text = (item as? String) ?? (item as? URL)?.absoluteString
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ShareQueueError.unsupportedText
                }
                self.saveFallbackCapture([
                    SharedMediaFile(path: text, mimeType: "text/plain", type: .text)
                ])
                try self.enqueueBackgroundAnalysis(imageData: nil, text: text, fallbackURL: nil)
            } catch {
                self.finishWithQueueFailure(error.localizedDescription)
            }
        }
    }

    private func decodeImage(_ item: NSSecureCoding?) throws -> UIImage {
        if let image = item as? UIImage { return image }
        if let data = item as? Data, let image = UIImage(data: data) { return image }
        if let url = item as? URL {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let image = UIImage(data: try Data(contentsOf: url)) { return image }
        }
        throw ShareQueueError.unsupportedImage
    }

    private func enqueueBackgroundAnalysis(
        imageData: Data?,
        text: String,
        fallbackURL: URL?
    ) throws {
        let jobId = UUID().uuidString.lowercased()
        let sessionIdentifier = sessionPrefix + jobId
        let requestPayload = try makeAnalysisRequest(
            imageData: imageData,
            text: text,
            jobId: jobId
        )
        let bodyURL = try writeSharedFile(
            data: requestPayload.body,
            name: "openloop-upload-\(jobId).body"
        )
        saveJobMetadata(
            sessionIdentifier: sessionIdentifier,
            bodyURL: bodyURL,
            fallbackURL: fallbackURL
        )

        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        configuration.sharedContainerIdentifier = appGroupId
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60
        let delegate = ShareBackgroundAnalysisDelegate(
            appGroupId: appGroupId,
            sessionIdentifier: sessionIdentifier
        )
        backgroundDelegate = delegate
        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.openloop.share-analysis-delegate.\(jobId)"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        backgroundSession = session
        let task = session.uploadTask(with: requestPayload.request, fromFile: bodyURL)
        task.taskDescription = jobId
        task.resume()

        recordPipelineStatus(phase: "queued", message: nil)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func makeAnalysisRequest(
        imageData: Data?,
        text: String,
        jobId: String
    ) throws -> RequestPayload {
        let defaults = UserDefaults(suiteName: appGroupId)
        let configured = defaults?.string(forKey: apiBaseURLKey)
        let plistValue = Bundle.main.object(forInfoDictionaryKey: "OpenLoopAPIBaseURL") as? String
        guard let rawBase = [configured, plistValue, defaultAPIBaseURL]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { throw ShareQueueError.invalidServerConfiguration }
        let baseURL = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let installationId = sharedInstallationId(defaults: defaults)
        let reference = ISO8601DateFormatter().string(from: Date())

        if let imageData {
            guard let url = URL(string: "\(baseURL)/v1/analyze/image") else {
                throw ShareQueueError.invalidServerConfiguration
            }
            let boundary = "OpenLoopBoundary\(UUID().uuidString)"
            var body = Data()
            body.appendMultipartField(name: "source", value: "image", boundary: boundary)
            body.appendMultipartField(name: "reference_at", value: reference, boundary: boundary)
            if !text.isEmpty {
                body.appendMultipartField(name: "companion_text", value: text, boundary: boundary)
            }
            body.appendMultipartFile(
                name: "file",
                filename: "shared.jpg",
                mimeType: "image/jpeg",
                data: imageData,
                boundary: boundary
            )
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(installationId, forHTTPHeaderField: "X-OpenLoop-Install-Id")
            request.setValue(jobId, forHTTPHeaderField: "X-OpenLoop-Analysis-Job-Id")
            if defaults?.bool(forKey: "openloop_live_activity_registered_v1") == true {
                request.setValue("preferred", forHTTPHeaderField: "X-OpenLoop-Live-Activity")
            }
            return RequestPayload(request: request, body: body)
        }

        guard let url = URL(string: "\(baseURL)/v1/analyze") else {
            throw ShareQueueError.invalidServerConfiguration
        }
        let json: [String: Any] = [
            "text": text,
            "source": "text",
            "reference_at": reference
        ]
        let body = try JSONSerialization.data(withJSONObject: json)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(installationId, forHTTPHeaderField: "X-OpenLoop-Install-Id")
        request.setValue(jobId, forHTTPHeaderField: "X-OpenLoop-Analysis-Job-Id")
        if defaults?.bool(forKey: "openloop_live_activity_registered_v1") == true {
            request.setValue("preferred", forHTTPHeaderField: "X-OpenLoop-Live-Activity")
        }
        return RequestPayload(request: request, body: body)
    }

    private func writeSharedFile(data: Data, name: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { throw ShareQueueError.appGroupUnavailable }
        let url = container.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func saveFallbackCapture(_ media: [SharedMediaFile]) {
        guard let data = try? JSONEncoder().encode(media) else { return }
        let defaults = UserDefaults(suiteName: appGroupId)
        defaults?.set(data, forKey: kUserDefaultsKey)
        defaults?.synchronize()
    }

    private func saveJobMetadata(
        sessionIdentifier: String,
        bodyURL: URL,
        fallbackURL: URL?
    ) {
        var metadata: [String: String] = [
            "body_path": bodyURL.path,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let fallbackURL { metadata["fallback_path"] = fallbackURL.path }
        let defaults = UserDefaults(suiteName: appGroupId)
        defaults?.set(metadata, forKey: jobKeyPrefix + sessionIdentifier)
        defaults?.synchronize()
    }

    private func sharedInstallationId(defaults: UserDefaults?) -> String {
        if let existing = defaults?.string(forKey: installationIdKey),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults?.set(created, forKey: installationIdKey)
        defaults?.synchronize()
        return created
    }

    private func finishWithQueueFailure(_ message: String) {
        recordPipelineStatus(phase: "queue_failed", message: message)
        let content = UNMutableNotificationContent()
        content.title = "공유 내용을 처리하지 못했어요"
        content.body = "OpenLoop에서 다시 시도해 주세요."
        content.sound = .default
        content.userInfo = ["openloop_event": "analysis_failed"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "openloop-share-failed-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func recordPipelineStatus(phase: String, message: String?) {
        var payload: [String: Any] = [
            "phase": phase,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        if let message { payload["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        UserDefaults(suiteName: appGroupId)?.set(data, forKey: pipelineStatusKey)
    }
}

private struct RequestPayload {
    let request: URLRequest
    let body: Data
}

private enum ShareQueueError: LocalizedError {
    case unsupportedImage
    case unsupportedText
    case imageEncoding
    case imageTooLarge
    case appGroupUnavailable
    case invalidServerConfiguration

    var errorDescription: String? {
        switch self {
        case .unsupportedImage: return "지원하지 않는 이미지 형식입니다."
        case .unsupportedText: return "공유된 텍스트를 읽지 못했습니다."
        case .imageEncoding: return "이미지를 업로드 형식으로 변환하지 못했습니다."
        case .imageTooLarge: return "이미지는 10MB 이하여야 합니다."
        case .appGroupUnavailable: return "공유 저장소에 접근하지 못했습니다."
        case .invalidServerConfiguration: return "분석 서버 설정을 확인해 주세요."
        }
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
}

private final class ShareBackgroundAnalysisDelegate: NSObject, URLSessionDataDelegate {
    private let appGroupId: String
    private let sessionIdentifier: String
    private let jobKeyPrefix = "background_analysis_job_v1."
    private let pendingDraftKey = "pending_draft_v1"
    private let pendingDraftJobKeyPrefix = "pending_draft_v1."
    private let pendingDraftLatestJobKey = "pending_draft_latest_job_v1"
    private var responseData = Data()

    init(appGroupId: String, sessionIdentifier: String) {
        self.appGroupId = appGroupId
        self.sessionIdentifier = sessionIdentifier
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        if error == nil,
           let statusCode,
           (200..<300).contains(statusCode),
           let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let event = object["event"] as? [String: Any],
           let title = event["title"] as? String,
           !title.isEmpty,
           let json = String(data: responseData, encoding: .utf8) {
            let liveActivityAccepted = (task.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "X-OpenLoop-Live-Activity") == "accepted"
            persistSuccess(
                json: json,
                title: title,
                liveActivityAccepted: liveActivityAccepted
            )
        } else {
            persistFailure()
        }
    }

    private func persistSuccess(
        json: String,
        title: String,
        liveActivityAccepted: Bool
    ) {
        let defaults = UserDefaults(suiteName: appGroupId)
        let jobId = normalizedJobId(from: sessionIdentifier)
        if let jobId {
            defaults?.set(json, forKey: pendingDraftJobKeyPrefix + jobId)
            defaults?.set(jobId, forKey: pendingDraftLatestJobKey)
        }
        defaults?.set(json, forKey: pendingDraftKey)
        removeJobFiles(removeFallback: true, defaults: defaults)
        defaults?.removeObject(forKey: kUserDefaultsKey)
        defaults?.removeObject(forKey: kUserDefaultsMessageKey)
        writePipelineStatus(phase: "completed", defaults: defaults)
        defaults?.synchronize()

        guard !liveActivityAccepted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(title) 정리 완료"
        content.body = "OpenLoop에서 분석 결과를 확인해 보세요."
        content.sound = .default
        var userInfo: [String: String] = [
            "payload": "draft:\(jobId ?? "pending")",
            "openloop_event": "analysis_result"
        ]
        if let jobId { userInfo["job_id"] = jobId }
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "openloop-analysis-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func persistFailure() {
        let defaults = UserDefaults(suiteName: appGroupId)
        removeJobFiles(removeFallback: false, defaults: defaults)
        writePipelineStatus(phase: "failed", defaults: defaults)
        defaults?.synchronize()

        let content = UNMutableNotificationContent()
        content.title = "공유한 내용을 분석하지 못했어요"
        content.body = "OpenLoop에서 다시 시도해 주세요."
        content.sound = .default
        content.userInfo = ["openloop_event": "analysis_failed"]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "openloop-analysis-failed-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        )
    }

    private func removeJobFiles(removeFallback: Bool, defaults: UserDefaults?) {
        let key = jobKeyPrefix + sessionIdentifier
        let metadata = defaults?.dictionary(forKey: key) as? [String: String]
        if let bodyPath = metadata?["body_path"] { removeSharedFile(atPath: bodyPath) }
        if removeFallback, let fallbackPath = metadata?["fallback_path"] {
            removeSharedFile(atPath: fallbackPath)
        }
        defaults?.removeObject(forKey: key)
    }

    private func removeSharedFile(atPath path: String) {
        guard let groupContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard fileURL.path.hasPrefix(groupContainer.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func writePipelineStatus(phase: String, defaults: UserDefaults?) {
        let payload: [String: String] = [
            "phase": phase,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        defaults?.set(data, forKey: "share_pipeline_status_v1")
    }

    private func normalizedJobId(from identifier: String) -> String? {
        let prefix = "com.openloop.openloopMobile.share-analysis."
        guard identifier.hasPrefix(prefix) else { return nil }
        let value = String(identifier.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
