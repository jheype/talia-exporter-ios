import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showLiveFeed = false
    @State private var search = ""
    @State private var selectedKind: CaptureEvent.Kind?
    @State private var period = ActivityPeriod.all
    private enum ActivityPeriod: String, CaseIterable { case all = "All dates", today = "Today", week = "Last 7 days" }

    private var filteredEvents: [CaptureEvent] {
        appModel.events.filter { event in
            let matchesDate = period == .all ||
                (period == .today && Calendar.current.isDateInToday(event.createdAt)) ||
                (period == .week && event.createdAt >= Date().addingTimeInterval(-7 * 86_400))
            return matchesDate && (selectedKind == nil || event.kind == selectedKind) &&
                (search.isEmpty || event.groupName.localizedCaseInsensitiveContains(search) || event.detail.localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Activity").font(.largeTitle.bold()).tracking(-0.8)
                        Spacer()
                        Button { Task { await appModel.refreshEvents() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(TaliaIconButtonStyle()).accessibilityLabel("Refresh activity")
                    }
                    HStack(spacing: 6) {
                        Text("Events").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.taliaTertiaryBackground, in: RoundedRectangle(cornerRadius: 12))
                        Button { showLiveFeed = true } label: {
                            Text("Live feed").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.plain)
                    }.padding(5).background(Color.taliaSecondaryBackground, in: RoundedRectangle(cornerRadius: 16))
                    WorkSearchField(text: $search, prompt: "Search activity")
                    HStack(spacing: 12) {
                        Menu {
                            Button("All events") { selectedKind = nil }
                            ForEach(CaptureEvent.Kind.allCases) { kind in
                                Button(kind.rawValue) { selectedKind = kind }
                            }
                        } label: { Label(selectedKind?.rawValue ?? "All events", systemImage: "chevron.down") }
                            .buttonStyle(TaliaSecondaryButtonStyle())
                        Menu {
                            ForEach(ActivityPeriod.allCases, id: \.self) { value in
                                Button(value.rawValue) { period = value }
                            }
                        } label: { Label(period.rawValue, systemImage: "calendar") }
                            .buttonStyle(TaliaSecondaryButtonStyle())
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEvents) { event in ActivityTimelineRow(event: event) }
                    }
                    if filteredEvents.isEmpty {
                        WorkEmptyState(title: "No matching activity", message: "Try another date, event type or search.", symbol: "clock")
                    }
                }.padding(20)
            }.taliaSurface().toolbar(.hidden, for: .navigationBar)
                .refreshable { await appModel.refreshEvents() }
                .sheet(isPresented: $showLiveFeed) { LiveFeedView() }
        }
    }
}

private struct ActivityTimelineRow: View {
    let event: CaptureEvent
    private var colour: Color { event.kind == .warning ? .orange : .taliaLive }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.time).font(.caption)
                if !Calendar.current.isDateInToday(event.createdAt) {
                    Text(event.createdAt, format: .dateTime.day().month(.abbreviated)).font(.caption2)
                }
            }.foregroundStyle(.secondary).frame(width: 44, alignment: .trailing).padding(.top, 3)
            VStack(spacing: 4) {
                Circle().fill(colour).frame(width: 8, height: 8)
                Rectangle().fill(Color.taliaSeparator).frame(width: 1)
            }.padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.detail).font(.subheadline.weight(.semibold))
                Text(event.groupName).font(.caption).foregroundStyle(.secondary)
                Text(event.kind.rawValue).font(.caption2).foregroundStyle(colour)
                Divider().padding(.top, 12)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 18)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }
}

