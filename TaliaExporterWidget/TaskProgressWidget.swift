import SwiftUI
import WidgetKit

struct TaliaTaskProgressWidget: Widget {
    let kind = "TaliaTaskProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExporterWidgetProvider()) { entry in
            TaskProgressWidgetView(entry: entry)
                .containerBackground(Color.widgetBackground, for: .widget)
                .widgetURL(URL(string: "talia-exporter://tasks"))
        }
        .configurationDisplayName("Talia Tasks")
        .description("See open work, blockers and live task progress.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct TaskProgressWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExporterWidgetEntry

    var body: some View {
        if entry.envelope == nil {
            WidgetUnavailableView(
                title: "Tasks not ready",
                detail: "Open Talia Exporter and configure Widgets."
            )
        } else if family == .systemSmall {
            small
        } else {
            medium
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Talia Tasks", systemImage: "checklist")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.snapshot.summary.totalOpen.formatted())
                    .font(.system(size: 34, weight: .bold, design: .default))
                Text("open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                metric(entry.snapshot.summary.dueToday, label: "today", colour: .orange)
                metric(entry.snapshot.summary.blocked, label: "blocked", colour: .red)
            }

            Text("Updated \(entry.snapshot.generatedAt, style: .relative) ago")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .privacySensitive()
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Talia Tasks", systemImage: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(entry.snapshot.summary.totalOpen) open")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if entry.snapshot.tasks.isEmpty {
                Spacer()
                Text("No tasks match the widget settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.snapshot.tasks.prefix(family == .systemLarge ? 6 : 2)) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(task.publicID)
                                .font(.system(size: 9, weight: .semibold, design: .default))
                                .foregroundStyle(.primary)
                            Text(task.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(task.progress)%")
                                .font(.caption2.weight(.semibold))
                        }
                        ProgressView(value: Double(task.progress), total: 100)
                            .tint(task.status == "blocked" ? .orange : .primary)
                    }
                }
            }
        }
        .privacySensitive()
    }

    private func metric(_ value: Int64, label: String, colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .font(.headline)
                .foregroundStyle(colour)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }
}

struct WidgetUnavailableView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.title2)
                .foregroundStyle(.primary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
