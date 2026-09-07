import SwiftUI
import WidgetKit

struct TaliaCapturedMessagesWidget: Widget {
    let kind = "TaliaCapturedMessagesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExporterWidgetProvider()) { entry in
            CapturedMessagesWidgetView(entry: entry)
                .widgetURL(URL(string: "talia-exporter://activity"))
                .containerBackground(Color.widgetBackground, for: .widget)
        }
        .configurationDisplayName("Talia Messages")
        .description("See the latest live messages from selected task and log groups.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct TaliaUKChatsCoverageWidget: Widget {
    let kind = "TaliaUKChatsCoverageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExporterWidgetProvider()) { entry in
            UKChatsCoverageWidgetView(entry: entry)
                .widgetURL(URL(string: "talia-exporter://groups"))
                .containerBackground(Color.widgetBackground, for: .widget)
        }
        .configurationDisplayName("UK Chats Coverage")
        .description("See captured messages, active groups and discarded messages.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct UKChatsCoverageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExporterWidgetEntry

    var body: some View {
        if entry.envelope == nil {
            WidgetUnavailableView(
                title: "Coverage not ready",
                detail: "Open Talia Exporter and configure Widgets."
            )
        } else if let coverage = entry.snapshot.ukChatsCoverage {
            if family == .systemSmall {
                small(coverage)
            } else {
                medium(coverage)
            }
        } else {
            WidgetUnavailableView(
                title: "Coverage not ready",
                detail: "Open Talia Exporter after the server update."
            )
        }
    }

    private func small(_ coverage: ExporterWidgetUKChatsCoverage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("UK Chats", systemImage: "chart.bar.doc.horizontal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(coverage.captured.formatted())
                    .font(.system(size: 31, weight: .bold, design: .default))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("captured")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                compactMetric(
                    coverage.activeGroups.formatted(),
                    label: "active groups",
                    colour: .green
                )
                compactMetric(
                    coverage.discarded.formatted(),
                    label: "discarded",
                    colour: .orange
                )
            }

            Text(coverage.period.title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private func medium(_ coverage: ExporterWidgetUKChatsCoverage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("UK Chats Coverage", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(coverage.period.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                coverageMetric(
                    coverage.captured.formatted(),
                    label: "Captured",
                    systemImage: "tray.and.arrow.down.fill",
                    colour: .primary
                )
                coverageMetric(
                    coverage.activeGroups.formatted(),
                    label: "Active groups",
                    systemImage: "dot.radiowaves.left.and.right",
                    colour: .green
                )
                coverageMetric(
                    coverage.discarded.formatted(),
                    label: "Discarded",
                    systemImage: "archivebox.fill",
                    colour: .orange
                )
            }

            HStack {
                Spacer()
                Text("Updated \(entry.snapshot.generatedAt, style: .relative) ago")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private func compactMetric(_ value: String, label: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.headline)
                .foregroundStyle(colour)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func coverageMetric(
        _ value: String,
        label: String,
        systemImage: String,
        colour: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(colour)
            Text(value)
                .font(.title2.bold())
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CapturedMessagesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExporterWidgetEntry

    private var maximumRows: Int { family == .systemLarge ? 5 : 2 }

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
                        .foregroundStyle(.primary)
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
                                .fill(.primary.opacity(0.15))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    Text(String((message.sender.first ?? "T")).uppercased())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.primary)
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
