import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct OpenLoopAnalysisAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable {
            case analyzing
            case completed
        }

        let phase: Phase
        let title: String
    }

    let jobId: String
}
