import Cocoa
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreGraphics

_ = NSApplication.shared

final class SimBridge: NSObject, @unchecked Sendable, SCStreamOutput {
    var targetWindow: SCWindow?
    var stream: SCStream?
    let boundary = "openloop-frame"
    let stdoutHandle = FileHandle.standardOutput
    let eventSource = CGEventSource(stateID: .combinedSessionState)
    let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    var currentTargetBounds: CGRect = .zero
    var lastBoundsCheckTime: CFAbsoluteTime = 0
    let titleBarHeightPoints: Double = 48.0

    func findSimulatorWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            ($0.owningApplication?.applicationName.contains("Simulator") ?? false) &&
            ($0.title?.contains("iPhone") ?? false || $0.title?.contains("iPad") ?? false || $0.title?.contains("iOS") ?? false)
        }) else {
            throw NSError(domain: "SimBridge", code: 404, userInfo: [NSLocalizedDescriptionKey: "Simulator device window not found. Please ensure iOS Simulator is booted."])
        }
        return window
    }

    func start() async throws {
        let window = try await findSimulatorWindow()
        self.targetWindow = window
        self.currentTargetBounds = window.frame

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 FPS
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
        fputs("[sim-bridge] Stream started for window \(window.windowID) (\(window.frame.width)x\(window.frame.height))\n", stderr)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.listenStdin()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let imageBuffer = sampleBuffer.imageBuffer else { return }

        let bufWidth = Double(CVPixelBufferGetWidth(imageBuffer))
        let bufHeight = Double(CVPixelBufferGetHeight(imageBuffer))

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let cropHeight = max(100.0, bufHeight - titleBarHeightPoints)
        let cropRect = CGRect(x: 0, y: 0, width: bufWidth, height: cropHeight)
        let cropped = ciImage.cropped(to: cropRect)

        guard let jpegData = ciContext.jpegRepresentation(
            of: cropped,
            colorSpace: rgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
        ) else { return }

        let header = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpegData.count)\r\n\r\n"
        let footer = "\r\n"

        if let headerData = header.data(using: .utf8), let footerData = footer.data(using: .utf8) {
            stdoutHandle.write(headerData)
            stdoutHandle.write(jpegData)
            stdoutHandle.write(footerData)
        }
    }

    func listenStdin() {
        while let line = readLine() {
            let parts = line.split(separator: " ")
            guard !parts.isEmpty else { continue }
            let command = String(parts[0])

            switch command {
            case "tap":
                if parts.count >= 3, let nx = Double(parts[1]), let ny = Double(parts[2]) {
                    self.performTap(nx: nx, ny: ny)
                }
            case "swipe":
                if parts.count >= 5,
                   let sx = Double(parts[1]), let sy = Double(parts[2]),
                   let ex = Double(parts[3]), let ey = Double(parts[4]) {
                    self.performSwipe(sx: sx, sy: sy, ex: ex, ey: ey)
                }
            default:
                break
            }
        }
        fputs("[sim-bridge] stdin closed, shutting down.\n", stderr)
        exit(0)
    }

    func updateWindowBoundsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastBoundsCheckTime < 0.5 { return }
        lastBoundsCheckTime = now

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for win in list {
                let owner = win[kCGWindowOwnerName as String] as? String ?? ""
                let name = win[kCGWindowName as String] as? String ?? ""
                if owner.contains("Simulator") && (name.contains("iPhone") || name.contains("iPad") || name.contains("iOS")) {
                    if let boundsDict = win[kCGWindowBounds as String] as? [String: Any] {
                        let x = boundsDict["X"] as? Double ?? self.currentTargetBounds.origin.x
                        let y = boundsDict["Y"] as? Double ?? self.currentTargetBounds.origin.y
                        let w = boundsDict["Width"] as? Double ?? self.currentTargetBounds.size.width
                        let h = boundsDict["Height"] as? Double ?? self.currentTargetBounds.size.height
                        self.currentTargetBounds = CGRect(x: x, y: y, width: w, height: h)
                    }
                    break
                }
            }
        }
    }

    func screenPoint(nx: Double, ny: Double) -> CGPoint {
        updateWindowBoundsIfNeeded()
        let availableHeight = max(100.0, self.currentTargetBounds.size.height - titleBarHeightPoints)
        let availableWidth = self.currentTargetBounds.size.width
        
        let x = self.currentTargetBounds.origin.x + nx * availableWidth
        let y = self.currentTargetBounds.origin.y + titleBarHeightPoints + ny * availableHeight
        return CGPoint(x: x, y: y)
    }

    func activateSimulatorIfNeeded() {
        if let simApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first {
            if !simApp.isActive {
                simApp.activate(options: .activateIgnoringOtherApps)
                usleep(30_000)
            }
        }
    }

    func performTap(nx: Double, ny: Double) {
        activateSimulatorIfNeeded()
        let point = screenPoint(nx: nx, ny: ny)
        fputs("[sim-bridge] Tap (\(nx), \(ny)) -> Screen (\(point.x), \(point.y))\n", stderr)

        let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        move?.post(tap: .cghidEventTap)
        usleep(20_000)
        down?.post(tap: .cghidEventTap)
        usleep(50_000)
        up?.post(tap: .cghidEventTap)
    }

    func performSwipe(sx: Double, sy: Double, ex: Double, ey: Double) {
        activateSimulatorIfNeeded()
        let startPoint = screenPoint(nx: sx, ny: sy)
        let endPoint = screenPoint(nx: ex, ny: ey)
        fputs("[sim-bridge] Swipe (\(sx), \(sy)) -> (\(ex), \(ey)) Screen (\(startPoint.x), \(startPoint.y)) -> (\(endPoint.x), \(endPoint.y))\n", stderr)

        let move = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: startPoint, mouseButton: .left)
        let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left)

        move?.post(tap: .cghidEventTap)
        usleep(20_000)
        down?.post(tap: .cghidEventTap)

        let steps = 14
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let currX = startPoint.x + (endPoint.x - startPoint.x) * progress
            let currY = startPoint.y + (endPoint.y - startPoint.y) * progress
            let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: currX, y: currY), mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(12_000)
        }

        usleep(25_000)
        let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
    }
}

let bridge = SimBridge()
Task {
    do {
        try await bridge.start()
    } catch {
        fputs("[sim-bridge] Fatal error: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()
