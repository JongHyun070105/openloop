import ActivityKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, URLSessionDataDelegate {
  private let appGroupId = "group.com.openloop.openloop_mobile"
  private let backgroundSessionPrefix = "com.openloop.openloopMobile.share-analysis."
  private let backgroundJobKeyPrefix = "background_analysis_job_v1."
  private let pendingDraftKey = "pending_draft_v1"
  private let pendingDraftJobKeyPrefix = "pending_draft_v1."
  private let pendingDraftLatestJobKey = "pending_draft_latest_job_v1"
  private let pendingDraftRequestKey = "pending_draft_request_v1"
  private let liveActivityTokenKey = "openloop_live_activity_push_to_start_token_v1"
  private let liveActivityRegisteredKey = "openloop_live_activity_registered_v1"
  private var backgroundSessions: [String: URLSession] = [:]
  private var backgroundCompletionHandlers: [String: () -> Void] = [:]
  private var backgroundResponseData: [String: Data] = [:]
  private let backgroundStateQueue = DispatchQueue(label: "com.openloop.background-analysis-state")
  private lazy var backgroundDelegateQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.openloop.background-analysis-delegate"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    GeneratedPluginRegistrant.register(with: self)
    startLiveActivityObservers()
    previewLiveActivityIfRequested()
    if let launchURL = launchOptions?[.url] as? URL {
      _ = recordPendingDraftRequest(from: launchURL)
    }

    let controller = window?.rootViewController as? FlutterViewController
    if let messenger = controller?.binaryMessenger {
      let channel = FlutterMethodChannel(name: "com.openloop.app/shared_group", binaryMessenger: messenger)
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        let userDefaults = UserDefaults(suiteName: self.appGroupId)
        if call.method == "configureShareExtension" {
          self.cleanupStaleBackgroundJobs(defaults: userDefaults)
          guard
            let arguments = call.arguments as? [String: Any],
            let apiBaseUrl = arguments["apiBaseUrl"] as? String,
            let installationId = arguments["installationId"] as? String,
            let parsedUrl = URL(string: apiBaseUrl),
            parsedUrl.scheme == "https",
            UUID(uuidString: installationId) != nil
          else {
            result(FlutterError(code: "invalid_share_configuration", message: "Invalid share extension configuration", details: nil))
            return
          }
          userDefaults?.set(apiBaseUrl, forKey: "openloop_api_base_url_v1")
          userDefaults?.set(installationId, forKey: "openloop_installation_id_v1")
          userDefaults?.synchronize()
          self.registerStoredLiveActivityToken()
          result(true)
        } else if call.method == "getSharedMedia" {
          if self.isBackgroundAnalysisQueued(defaults: userDefaults) {
            result(nil)
          } else if let data = userDefaults?.data(forKey: "ShareKey") {
            let jsonString = String(data: data, encoding: .utf8)
            result(jsonString)
          } else {
            result(nil)
          }
        } else if call.method == "clearSharedMedia" {
          if
            let groupContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: self.appGroupId),
            let data = userDefaults?.data(forKey: "ShareKey"),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
          {
            for item in items {
              guard let path = item["path"] as? String else { continue }
              let fileUrl = URL(fileURLWithPath: path).standardizedFileURL
              if fileUrl.path.hasPrefix(groupContainer.standardizedFileURL.path + "/") {
                try? FileManager.default.removeItem(at: fileUrl)
              }
            }
          }
          userDefaults?.removeObject(forKey: "ShareKey")
          userDefaults?.removeObject(forKey: "ShareMessageKey")
          userDefaults?.synchronize()
          result(true)
        } else if call.method == "getPendingDraft" {
          if self.hasJobIdArgument(call.arguments), self.jobId(from: call.arguments) == nil {
            result(nil)
            return
          }
          let jobId = self.jobId(from: call.arguments)
          let key = jobId.map { self.pendingDraftJobKeyPrefix + $0 } ?? self.pendingDraftKey
          if let draftJson = userDefaults?.string(forKey: key) {
            result(draftJson)
          } else {
            result(nil)
          }
        } else if call.method == "clearPendingDraft" {
          if self.hasJobIdArgument(call.arguments), self.jobId(from: call.arguments) == nil {
            result(false)
            return
          }
          if let jobId = self.jobId(from: call.arguments) {
            let jobKey = self.pendingDraftJobKeyPrefix + jobId
            let jobDraft = userDefaults?.string(forKey: jobKey)
            userDefaults?.removeObject(forKey: jobKey)
            if userDefaults?.string(forKey: self.pendingDraftLatestJobKey) == jobId {
              if userDefaults?.string(forKey: self.pendingDraftKey) == jobDraft {
                userDefaults?.removeObject(forKey: self.pendingDraftKey)
              }
              userDefaults?.removeObject(forKey: self.pendingDraftLatestJobKey)
            }
          } else {
            userDefaults?.removeObject(forKey: self.pendingDraftKey)
            userDefaults?.removeObject(forKey: self.pendingDraftLatestJobKey)
          }
          userDefaults?.synchronize()
          result(true)
        } else if call.method == "getPendingDraftRequest" {
          result(userDefaults?.string(forKey: self.pendingDraftRequestKey))
        } else if call.method == "clearPendingDraftRequest" {
          if let jobId = self.jobId(from: call.arguments),
             userDefaults?.string(forKey: self.pendingDraftRequestKey) == jobId {
            userDefaults?.removeObject(forKey: self.pendingDraftRequestKey)
            userDefaults?.synchronize()
          }
          result(true)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let handledDraft = recordPendingDraftRequest(from: url)
    return super.application(app, open: url, options: options) || handledDraft
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let jobId = response.notification.request.content.userInfo["job_id"] as? String {
      recordPendingDraftRequest(jobId: jobId)
    }
    super.userNotificationCenter(
      center,
      didReceive: response,
      withCompletionHandler: completionHandler
    )
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if UIApplication.shared.applicationState == .active,
       notification.request.content.userInfo["openloop_event"] as? String == "analysis_result" {
      completionHandler([])
      return
    }
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge, .list])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier.hasPrefix(backgroundSessionPrefix) else {
      completionHandler()
      return
    }
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sharedContainerIdentifier = appGroupId
    configuration.sessionSendsLaunchEvents = true
    let session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: backgroundDelegateQueue
    )
    backgroundStateQueue.sync {
      backgroundCompletionHandlers[identifier] = completionHandler
      backgroundSessions[identifier] = session
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard let identifier = session.configuration.identifier else { return }
    let key = responseKey(sessionIdentifier: identifier, taskIdentifier: dataTask.taskIdentifier)
    backgroundStateQueue.sync {
      backgroundResponseData[key, default: Data()].append(data)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let identifier = session.configuration.identifier else { return }
    guard UserDefaults(suiteName: appGroupId)?.object(
      forKey: backgroundJobKeyPrefix + identifier
    ) != nil else { return }
    let key = responseKey(sessionIdentifier: identifier, taskIdentifier: task.taskIdentifier)
    let data = backgroundStateQueue.sync {
      backgroundResponseData.removeValue(forKey: key) ?? Data()
    }
    let statusCode = (task.response as? HTTPURLResponse)?.statusCode

    if error == nil,
       let statusCode,
       (200..<300).contains(statusCode),
       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let event = object["event"] as? [String: Any],
       let title = event["title"] as? String,
       !title.isEmpty,
       let json = String(data: data, encoding: .utf8) {
      let liveActivityAccepted = (task.response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "X-OpenLoop-Live-Activity") == "accepted"
      persistCompletedAnalysis(
        json: json,
        title: title,
        sessionIdentifier: identifier,
        liveActivityAccepted: liveActivityAccepted
      )
    } else {
      persistFailedAnalysis(sessionIdentifier: identifier)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else { return }
    let completionHandler = backgroundStateQueue.sync {
      let handler = backgroundCompletionHandlers.removeValue(forKey: identifier)
      backgroundSessions.removeValue(forKey: identifier)
      return handler
    }
    DispatchQueue.main.async { completionHandler?() }
  }

  private func persistCompletedAnalysis(
    json: String,
    title: String,
    sessionIdentifier: String,
    liveActivityAccepted: Bool
  ) {
    let defaults = UserDefaults(suiteName: appGroupId)
    let jobId = jobId(fromSessionIdentifier: sessionIdentifier)
    if let jobId {
      defaults?.set(json, forKey: pendingDraftJobKeyPrefix + jobId)
      defaults?.set(jobId, forKey: pendingDraftLatestJobKey)
    }
    defaults?.set(json, forKey: pendingDraftKey)
    removeJobFilesAndMetadata(
      sessionIdentifier: sessionIdentifier,
      removeFallback: true,
      defaults: defaults
    )
    defaults?.removeObject(forKey: "ShareKey")
    defaults?.removeObject(forKey: "ShareMessageKey")
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

  private func persistFailedAnalysis(sessionIdentifier: String) {
    let defaults = UserDefaults(suiteName: appGroupId)
    removeJobFilesAndMetadata(
      sessionIdentifier: sessionIdentifier,
      removeFallback: false,
      defaults: defaults
    )
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

  private func removeJobFilesAndMetadata(
    sessionIdentifier: String,
    removeFallback: Bool,
    defaults: UserDefaults?
  ) {
    let key = backgroundJobKeyPrefix + sessionIdentifier
    let metadata = defaults?.dictionary(forKey: key) as? [String: String]
    if let bodyPath = metadata?["body_path"] {
      removeSharedFile(atPath: bodyPath)
    }
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

  private func isBackgroundAnalysisQueued(defaults: UserDefaults?) -> Bool {
    guard let defaults else { return false }
    let formatter = ISO8601DateFormatter()
    return defaults.dictionaryRepresentation().contains { key, value in
      guard
        key.hasPrefix(backgroundJobKeyPrefix),
        let metadata = value as? [String: String],
        let createdAtValue = metadata["created_at"],
        let createdAt = formatter.date(from: createdAtValue)
      else { return false }
      return Date().timeIntervalSince(createdAt) < 120
    }
  }

  private func cleanupStaleBackgroundJobs(defaults: UserDefaults?) {
    guard let defaults else { return }
    let formatter = ISO8601DateFormatter()
    for (key, value) in defaults.dictionaryRepresentation() {
      guard
        key.hasPrefix(backgroundJobKeyPrefix),
        let metadata = value as? [String: String],
        let createdAtValue = metadata["created_at"],
        let createdAt = formatter.date(from: createdAtValue),
        Date().timeIntervalSince(createdAt) >= 120
      else { continue }
      if let bodyPath = metadata["body_path"] { removeSharedFile(atPath: bodyPath) }
      defaults.removeObject(forKey: key)
    }
    defaults.synchronize()
  }

  private func responseKey(sessionIdentifier: String, taskIdentifier: Int) -> String {
    "\(sessionIdentifier)#\(taskIdentifier)"
  }

  private func jobId(from arguments: Any?) -> String? {
    guard
      let values = arguments as? [String: Any],
      let rawJobId = values["jobId"] as? String
    else { return nil }
    return normalizedJobId(rawJobId)
  }

  private func hasJobIdArgument(_ arguments: Any?) -> Bool {
    guard let values = arguments as? [String: Any] else { return false }
    return values.keys.contains("jobId")
  }

  private func jobId(fromSessionIdentifier identifier: String) -> String? {
    guard identifier.hasPrefix(backgroundSessionPrefix) else { return nil }
    return normalizedJobId(String(identifier.dropFirst(backgroundSessionPrefix.count)))
  }

  private func normalizedJobId(_ value: String) -> String? {
    guard let uuid = UUID(uuidString: value) else { return nil }
    return uuid.uuidString.lowercased()
  }

  private func recordPendingDraftRequest(from url: URL) -> Bool {
    guard
      url.scheme?.lowercased() == "openloop",
      url.host?.lowercased() == "draft",
      let rawJobId = url.pathComponents.dropFirst().first,
      let jobId = normalizedJobId(rawJobId)
    else { return false }
    recordPendingDraftRequest(jobId: jobId)
    return true
  }

  private func recordPendingDraftRequest(jobId rawJobId: String) {
    guard let jobId = normalizedJobId(rawJobId) else { return }
    let defaults = UserDefaults(suiteName: appGroupId)
    defaults?.set(jobId, forKey: pendingDraftRequestKey)
    if let json = defaults?.string(forKey: pendingDraftJobKeyPrefix + jobId) {
      defaults?.set(json, forKey: pendingDraftKey)
      defaults?.set(jobId, forKey: pendingDraftLatestJobKey)
    }
    defaults?.synchronize()
  }

  private func startLiveActivityObservers() {
    guard #available(iOS 17.2, *) else { return }

    Task {
      for await tokenData in Activity<OpenLoopAnalysisAttributes>.pushToStartTokenUpdates {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults(suiteName: appGroupId)
        defaults?.set(token, forKey: liveActivityTokenKey)
        defaults?.synchronize()
        registerStoredLiveActivityToken()
      }
    }

    Task {
      for await activity in Activity<OpenLoopAnalysisAttributes>.activityUpdates {
        guard activity.content.state.phase == .completed else { continue }
        Task {
          try? await Task.sleep(for: .seconds(15))
          let finalContent = ActivityContent(
            state: activity.content.state,
            staleDate: nil
          )
          await activity.end(
            finalContent,
            dismissalPolicy: .immediate
          )
        }
      }
    }
  }

  private func registerStoredLiveActivityToken() {
    guard #available(iOS 17.2, *) else { return }
    let defaults = UserDefaults(suiteName: appGroupId)
    guard
      ActivityAuthorizationInfo().areActivitiesEnabled,
      let token = defaults?.string(forKey: liveActivityTokenKey),
      token.count >= 20,
      let baseUrl = defaults?.string(forKey: "openloop_api_base_url_v1"),
      let installationId = defaults?.string(forKey: "openloop_installation_id_v1"),
      UUID(uuidString: installationId) != nil,
      let url = URL(string: baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/devices/live-activity-token")
    else {
      defaults?.set(false, forKey: liveActivityRegisteredKey)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(installationId, forHTTPHeaderField: "X-OpenLoop-Install-Id")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

    URLSession.shared.dataTask(with: request) { _, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let registered = (200..<300).contains(status)
      let currentDefaults = UserDefaults(suiteName: self.appGroupId)
      currentDefaults?.set(registered, forKey: self.liveActivityRegisteredKey)
      currentDefaults?.synchronize()
    }.resume()
  }

  private func previewLiveActivityIfRequested() {
    guard ProcessInfo.processInfo.arguments.contains("-OpenLoopPreviewLiveActivity") else {
      return
    }
    guard #available(iOS 16.2, *) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      let attributes = OpenLoopAnalysisAttributes(jobId: "debug-preview")
      let state = OpenLoopAnalysisAttributes.ContentState(
        phase: .completed,
        title: "저녁 약속"
      )
      do {
        _ = try Activity.request(
          attributes: attributes,
          content: ActivityContent(state: state, staleDate: nil),
          pushType: nil
        )
      } catch {
        NSLog("OpenLoop Live Activity preview failed: %@", error.localizedDescription)
        return
      }
    }
  }
}
