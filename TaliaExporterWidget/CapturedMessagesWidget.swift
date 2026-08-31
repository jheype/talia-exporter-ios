import SwiftUI
import WidgetKit

struct TaliaCapturedMessagesWidget: Widget {
    let kind = "TaliaCapturedMessagesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExporterWidgetProvider()) { entry in
            CapturedMessagesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Talia Messages")
        .description("See the latest live messages from selected task and log groups.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private struct CapturedMessagesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExporterWidgetEntry

    private var maximumRows: Int { family == .systemLarge ? 6 : 3 }

    var body: some View {
        if entry.envelope == nil {
            WidgetUnavailableView(
                title: "Messages not ready",
                detail: "Open Talia Exporter and configure Widgets."
            )
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Captured messages", systemImage: "message.badge")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                    Spacer()
                    Text(entry.snapshot.generatedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if entry.snapshot.messages.isEmpty {
                    Spacer()
                    Text("No live task or log messages match the widget settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(entry.snapshot.messages.prefix(maximumRows)) { message in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(.blue.opacity(0.15))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Text(String((message.sender.first ?? "T")).uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.blue)
                                }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(message.groupName)
                                        .font(.caption2.weight(.semibold))
                                        .lineLimit(1)
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(message.timestamp, style: .relative)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Text(message.body)
                                    .font(.caption)
                                    .lineLimit(family == .systemLarge ? 2 : 1)
                            }
                        }
                    }
                }
            }
            .privacySensitive()
        }
    }
}
