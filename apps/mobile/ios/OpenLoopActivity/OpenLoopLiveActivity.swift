import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OpenLoopActivityBundle: WidgetBundle {
    var body: some Widget {
        OpenLoopAnalysisLiveActivity()
    }
}

struct OpenLoopAnalysisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenLoopAnalysisAttributes.self) { context in
            LockScreenActivityView(state: context.state)
                .activityBackgroundTint(Color.white)
                .activitySystemActionForegroundColor(Color(red: 0.14, green: 0.42, blue: 0.99))
                .widgetURL(draftURL(jobId: context.attributes.jobId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityMark(state: context.state, size: 22)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.phase == .completed ? "정리 완료" : "OpenLoop 분석 중")
                            .font(.headline)
                        Text(context.state.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.phase == .completed ? "탭해서 분석 결과 보기" : "공유한 내용을 일정으로 정리하고 있어요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                ActivityMark(state: context.state, size: 16)
            } compactTrailing: {
                if context.state.phase == .completed {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    ProgressView()
                        .tint(.blue)
                }
            } minimal: {
                ActivityMark(state: context.state, size: 14)
            }
            .keylineTint(Color(red: 0.14, green: 0.42, blue: 0.99))
            .widgetURL(draftURL(jobId: context.attributes.jobId))
        }
    }

    private func draftURL(jobId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "openloop"
        components.host = "draft"
        components.path = "/\(jobId)"
        return components.url
    }
}

private struct LockScreenActivityView: View {
    let state: OpenLoopAnalysisAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ActivityMark(state: state, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.phase == .completed ? "정리 완료" : "OpenLoop 분석 중")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.04, green: 0.11, blue: 0.23))
                Text(state.title)
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.38, green: 0.44, blue: 0.53))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.phase == .completed {
                Text("결과 보기")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.42, blue: 0.99))
            } else {
                ProgressView()
                    .tint(Color(red: 0.14, green: 0.42, blue: 0.99))
            }
        }
        .padding(16)
    }
}

private struct ActivityMark: View {
    let state: OpenLoopAnalysisAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Image(systemName: state.phase == .completed ? "checkmark.circle.fill" : "sparkles")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(state.phase == .completed ? Color.green : Color.blue)
            .accessibilityLabel(state.phase == .completed ? "분석 완료" : "분석 중")
    }
}
