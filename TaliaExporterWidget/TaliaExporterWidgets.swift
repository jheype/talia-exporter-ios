import SwiftUI
import WidgetKit

struct ExporterWidgetEntry: TimelineEntry {
    let date: Date
    let envelope: ExporterWidgetEnvelope?

    var snapshot: ExporterWidgetSnapshot {
        envelope?.snapshot ?? .empty
    }
}

struct ExporterWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExporterWidgetEntry {
        ExporterWidgetEntry(
            date: Date(),
            envelope: ExporterWidgetEnvelope(
                ownerUserID: UUID(),
                savedAt: Date(),
                snapshot: .preview
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ExporterWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(ExporterWidgetEntry(date: Date(), envelope: WidgetSharedStore.loadEnvelope()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExporterWidgetEntry>) -> Void) {
        let entry = ExporterWidgetEntry(date: Date(), envelope: WidgetSharedStore.loadEnvelope())
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

@main
struct TaliaExporterWidgetBundle: WidgetBundle {
    var body: some Widget {
        TaliaTaskProgressWidget()
        TaliaCapturedMessagesWidget()
        TaliaUKChatsCoverageWidget()
    }
}
