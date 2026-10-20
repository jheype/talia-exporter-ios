import SwiftUI
import Charts

/// CRM users: how they use Talia, churn risk, and the team's outreach.
/// Server: /api/admin/user-analytics (super admin + verified MFA).
enum SAUserFilter: String, CaseIterable, Identifiable {
    case all, atRisk = "at_risk", inactive, warm, followUpDue = "follow_up_due", notContacted = "not_contacted", internalOnly = "internal"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .atRisk: "Churn risk"
        case .inactive: "Inactive 2+ days"
        case .warm: "Warm"
        case .followUpDue: "Follow-ups due"
        case .notContacted: "Not contacted 30d"
        case .internalOnly: "Internal"
        }
    }
}

enum SAUserStage: String, CaseIterable, Identifiable {
    case champion, warm, neutral, cold, doNotContact = "do_not_contact"
    var id: String { rawValue }
    var title: String { self == .doNotContact ? "Do not contact" : rawValue.capitalized }
}

let saOutreachChannels: [(String, String)] = [("call", "Call"), ("whatsapp", "WhatsApp"), ("email", "Email"), ("in_person", "In person"), ("other", "Other")]
let saOutreachOutcomes: [(String, String)] = [("reached", "Spoke to them"), ("no_answer", "No answer"), ("positive", "Positive"), ("negative", "Negative"), ("follow_up", "Needs follow-up")]
func saChoiceTitle(_ list: [(String, String)], _ key: String) -> String { list.first { $0.0 == key }?.1 ?? saLabel(key) }

/// "1h 20m", "45m", "under 1m".
func saDuration(_ seconds: Double?) -> String {
    let total = Int(seconds ?? 0)
    if total < 60 { return total == 0 ? "0m" : "under 1m" }
    let hours = total / 3600, minutes = (total % 3600) / 60
    return hours > 0 ? (minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h") : "\(minutes)m"
}

func saDate(_ text: String) -> Date? {
    let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

func saHealthColor(_ status: String) -> Color {
    switch status {
    case "active": .green
    case "new": .blue
    case "cooling": .orange
    case "at_risk", "dormant": .red
    default: .secondary
    }
}

struct SAHealthBadge: View {
    let health: SAValue
    var body: some View {
        let status = health["status"].text
        Text(status == "at_risk" ? "At risk" : saLabel(status))
            .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(saHealthColor(status)).background(saHealthColor(status).opacity(0.14), in: Capsule())
    }
}

struct SAUsersView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @State private var filter: SAUserFilter = .all
    @State private var days = 30
    @State private var query = ""
    @State private var response: SAValue = .null
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var runningDigest = false
    @State private var digestMessage: String?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SAUserFilter.allCases) { item in
                            let count = response["counts"][item.rawValue].text
                            Button(count.isEmpty ? item.title : "\(item.title) · \(count)") { filter = item }
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(filter == item ? Color.taliaAccent : Color.taliaSecondaryBackground, in: Capsule())
                                .foregroundStyle(filter == item ? Color.taliaOnAccent : Color.taliaAccent)
                                .accessibilityAddTraits(filter == item ? .isSelected : [])
                                .buttonStyle(.plain)
                        }
                    }
                }
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.pickerStyle(.segmented)
            }.listRowBackground(Color.clear)
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } } }
            if loading && response.isNull { ProgressView("Loading people…") }
            Section {
                ForEach(response["items"].array, id: \.recordID) { user in
                    NavigationLink { SAUserAnalyticsView(store: store, userID: user.recordID, title: displayName(user)) } label: { row(user) }
                        .listRowBackground(Color.taliaSecondaryBackground)
                }
            }
            if !loading && error == nil && !response.isNull && response["items"].array.isEmpty {
                ContentUnavailableView("Nobody here", systemImage: "person.2", description: Text("No people match this filter."))
            }
            Section {
                Button(runningDigest ? "Sending…" : "Send today's inactivity digest now") { Task { await runDigest() } }.disabled(runningDigest)
                if let digestMessage { Text(digestMessage).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Each morning from 9:00 UK time you get one alert listing people who stopped using Talia on desktop or phone 2 to 14 days ago, plus follow-ups due. Each person is reported once per lapse. Sending now uses up today's digest.")
            }
        }.taliaSurface().navigationTitle("Users")
        .searchable(text: $query, prompt: "Name, email or company")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: query) { _, value in if value.isEmpty { Task { await load() } } }
        .onChange(of: filter) { _, _ in Task { await load() } }
        .onChange(of: days) { _, _ in Task { await load() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private func displayName(_ user: SAValue) -> String { user["name"].text.isEmpty ? user["email"].text : user["name"].text }

    private func row(_ user: SAValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName(user)).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                SAHealthBadge(health: user["health"])
            }
            Text(user["tenant"]["name"].text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 10) {
                if let last = saDate(user["last_activity_at"].text) {
                    Label { Text(last, style: .relative) + Text(" ago") } icon: { Image(systemName: "clock") }
                } else { Label("Never used", systemImage: "clock") }
                Label(saDuration(user["active_seconds"]["window"].number), systemImage: "hourglass")
                if !user["top_area"].isNull { Text(user["top_area"]["label"].text).lineLimit(1) }
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if !user["relationship"]["stage"].isNull {
                    Text(SAUserStage(rawValue: user["relationship"]["stage"].text)?.title ?? "").font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Color.taliaTertiaryBackground, in: Capsule())
                }
                let lastOutreach = user["relationship"]["last_outreach"]
                if !lastOutreach.isNull, let at = saDate(lastOutreach["at"].text) {
                    Text("Contacted \(at.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
                if let due = saDayDate(user["relationship"]["follow_up_at"].text) {
                    Label(due.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.orange)
                }
            }
        }.padding(.vertical, 4)
    }

    private func load() async {
        guard let api = store.api else { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let scope = store.sessionRevision
        var components = URLComponents()
        components.queryItems = [.init(name: "days", value: String(days)), .init(name: "filter", value: filter.rawValue)]
        if !query.isEmpty { components.queryItems?.append(.init(name: "q", value: query)) }
        // URLComponents leaves "+" alone, which servers read as a space ("lucas+test@…").
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        do {
            let result = try await api.request("admin/user-analytics?" + encoded)
            guard generation == current, scope == store.sessionRevision, !Task.isCancelled else { return }
            if result["items"].isNull { throw SARequestError(status: 502, code: "CONTRACT", message: "The server response has changed. Refresh or update the app.") }
            response = result
        } catch {
            if generation == current && scope == store.sessionRevision && !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if generation == current { loading = false }
    }

    private func runDigest() async {
        guard let api = store.api else { return }
        runningDigest = true; digestMessage = nil
        defer { runningDigest = false }
        do {
            let result = try await api.request("admin/user-analytics/digest/run", method: "POST", body: [:])
            digestMessage = result["sent"].flag
                ? "Sent: \(result["inactive"].text) inactive, \(result["followUps"].text) follow-ups. Check Alerts."
                : "Not sent: \(result["reason"].text)."
        } catch { digestMessage = error.localizedDescription }
    }
}

struct SAUserAnalyticsView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let userID: String
    let title: String
    @State private var days = 30
    @State private var detail: SAValue = .null
    @State private var meta: SAValue = .null
    @State private var loading = false
    @State private var error: String?
    @State private var loggingOutreach = false
    @State private var editingRelationship = false
    @State private var generation = UUID()
    @State private var pendingDelete: SAValue?

    private var user: SAValue { detail["user"] }
    var body: some View {
        List {
            if loading && detail.isNull { ProgressView("Loading activity…") }
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } } }
            if !detail.isNull { content }
        }.taliaSurface().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Log outreach", systemImage: "phone.arrow.up.right") { loggingOutreach = true }
                Button("Edit relationship", systemImage: "person.crop.circle.badge.checkmark") { editingRelationship = true }
            } label: { Image(systemName: "plus") }.disabled(detail.isNull)
        }
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: days) { _, _ in Task { await load() } }
        .confirmationDialog("Delete this outreach entry? This can't be undone.", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.recordID { Task { await deleteOutreach(id) } }
                pendingDelete = nil
            }
        }
        .sheet(isPresented: $loggingOutreach, onDismiss: { Task { await load() } }) {
            SAOutreachForm(store: store, userID: userID, name: title)
        }
        .sheet(isPresented: $editingRelationship, onDismiss: { Task { await load() } }) {
            SARelationshipForm(store: store, userID: userID, relationship: user["relationship"], owners: meta["owners"].array)
        }
    }

    @ViewBuilder private var content: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text(user["tenant"]["name"].text).font(.headline); Spacer(); SAHealthBadge(health: user["health"]) }
                Text(user["health"]["reason"].text).font(.subheadline).foregroundStyle(.secondary)
                Text(user["email"].text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(.vertical, 4)
            if let last = saDate(user["last_activity_at"].text) {
                LabeledContent("Last used", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let login = saDate(user["last_login_at"].text) {
                LabeledContent("Last sign-in", value: login.formatted(date: .abbreviated, time: .shortened))
            }
            if let joined = saDate(user["joined_at"].text) {
                LabeledContent("Joined", value: joined.formatted(date: .abbreviated, time: .omitted))
            }
        }
        Section("Relationship") {
            let rel = user["relationship"]
            LabeledContent("Stage", value: SAUserStage(rawValue: rel["stage"].text)?.title ?? "Not set")
            LabeledContent("Owner", value: rel["owner"]["email"].text.isEmpty ? "Nobody" : rel["owner"]["email"].text)
            LabeledContent("Follow up", value: saDayDate(rel["follow_up_at"].text)?.formatted(date: .abbreviated, time: .omitted) ?? "None")
            if !rel["note"].text.isEmpty { Text(rel["note"].text).font(.subheadline) }
            if rel["is_internal"].flag { Label("Internal or test account: not alerted on", systemImage: "eye.slash").font(.footnote).foregroundStyle(.secondary) }
            Button("Log outreach") { loggingOutreach = true }
            Button("Edit relationship") { editingRelationship = true }
        }
        Section {
            Picker("Period", selection: $days) {
                Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }.pickerStyle(.segmented)
            let time = user["active_seconds"]
            LabeledContent("Active time", value: saDuration(time["window"].number))
            LabeledContent("Desktop · Phone", value: "\(saDuration(time["desktop"].number)) · \(saDuration(time["mobile"].number))")
            LabeledContent("Last 7 days", value: saDuration(time["last_7_days"].number))
            LabeledContent("Last 2 weeks vs 2 before", value: "\(saDuration(time["last_14_days"].number)) vs \(saDuration(time["previous_14_days"].number))")
            Chart(Array(detail["daily_seconds"].array.enumerated()), id: \.offset) { _, day in
                BarMark(x: .value("Day", saDay(day["date"].text), unit: .day), y: .value("Minutes", (day["desktop"].number ?? 0) / 60))
                    .foregroundStyle(by: .value("Client", "Desktop"))
                BarMark(x: .value("Day", saDay(day["date"].text), unit: .day), y: .value("Minutes", (day["mobile"].number ?? 0) / 60))
                    .foregroundStyle(by: .value("Client", "Phone"))
            }
            .chartForegroundStyleScale(["Desktop": Color.taliaAccent, "Phone": Color.orange])
            .chartYAxisLabel("Minutes").frame(height: 180)
        } header: { Text("Time in Talia") }
        if !detail["areas"].array.isEmpty {
            Section("Where they spend time") {
                let top = detail["areas"].array.first?["seconds"].number ?? 1
                ForEach(Array(detail["areas"].array.enumerated()), id: \.offset) { _, area in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(area["label"].text); Spacer(); Text(saDuration(area["seconds"].number)).foregroundStyle(.secondary) }
                        GeometryReader { proxy in
                            Capsule().fill(Color.taliaAccent.opacity(0.7))
                                .frame(width: max(4, proxy.size.width * CGFloat((area["seconds"].number ?? 0) / max(top, 1))))
                        }.frame(height: 5)
                    }.padding(.vertical, 2)
                }
            }
        }
        Section {
            if detail["actions"].array.isEmpty { Text("No recorded actions in this period.").foregroundStyle(.secondary) }
            ForEach(Array(detail["actions"].array.enumerated()), id: \.offset) { _, action in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action["label"].text)
                        Text(action["area_label"].text).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(action["count"].text).font(.body.monospacedDigit().weight(.semibold))
                }
            }
        } header: { Text("What they did") } footer: { Text("From the CRM's request log (desktop and phone). Kept for 90 days.") }
        if !detail["timeline"].array.isEmpty {
            Section("Recent activity") {
                ForEach(Array(detail["timeline"].array.prefix(40).enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top) {
                        Image(systemName: event["platform"].text == "mobile" ? "iphone" : "desktopcomputer").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event["count"].number ?? 1 > 1 ? "\(event["label"].text) ×\(event["count"].text)" : event["label"].text)
                            if let at = saDate(event["at"].text) { Text(at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        Section("Outreach") {
            if detail["outreach"].array.isEmpty { Text("Nobody has logged contact yet.").foregroundStyle(.secondary) }
            ForEach(detail["outreach"].array, id: \.recordID) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(saChoiceTitle(saOutreachChannels, item["channel"].text)) · \(saChoiceTitle(saOutreachOutcomes, item["outcome"].text))").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let at = saDate(item["contacted_at"].text) { Text(at.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if !item["note"].text.isEmpty { Text(item["note"].text).font(.subheadline) }
                    if !item["created_by_email"].text.isEmpty { Text("by \(item["created_by_email"].text)").font(.caption).foregroundStyle(.secondary) }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) { pendingDelete = item }
                }
            }
        }
    }

    /// The server's day label as a local calendar day, which is how Charts bins `.day`.
    private func saDay(_ text: String) -> Date { saDayDate(text) ?? Date() }

    private func load() async {
        guard let api = store.api, UUID(uuidString: userID) != nil else { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let scope = store.sessionRevision
        do {
            let value = try await api.request("admin/user-analytics/\(userID)?days=\(days)")
            guard generation == current, scope == store.sessionRevision, !Task.isCancelled else { return }
            detail = value
            if meta.isNull, let loaded = try? await api.request("admin/user-analytics/meta"), scope == store.sessionRevision { meta = loaded }
        } catch {
            if generation == current && scope == store.sessionRevision && !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if generation == current { loading = false }
    }

    private func deleteOutreach(_ id: String) async {
        guard let api = store.api, UUID(uuidString: id) != nil else { return }
        do { _ = try await api.request("admin/user-analytics/\(userID)/outreach/\(id)", method: "DELETE"); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct SAOutreachForm: View {
    @ObservedObject var store: SuperAdminPortalStore
    let userID: String, name: String
    @Environment(\.dismiss) private var dismiss
    @State private var channel = "whatsapp"
    @State private var outcome = "reached"
    @State private var note = ""
    @State private var contactedAt = Date()
    @State private var setFollowUp = false
    @State private var followUp = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("Channel", selection: $channel) { ForEach(saOutreachChannels, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("Outcome", selection: $outcome) { ForEach(saOutreachOutcomes, id: \.0) { Text($0.1).tag($0.0) } }
                DatePicker("When", selection: $contactedAt, in: ...Date())
                Section("Note") { TextField("What was said, what they need", text: $note, axis: .vertical).lineLimit(3...8) }
                Section {
                    Toggle("Set a follow-up", isOn: $setFollowUp)
                    if setFollowUp { DatePicker("Follow up on", selection: $followUp, in: Date()..., displayedComponents: .date) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Contact with \(name)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || note.count > 2000) }
            }
        }
    }
    private func save() async {
        guard let api = store.api else { return }
        saving = true; error = nil
        var body: [String: SAValue] = ["channel": .string(channel), "outcome": .string(outcome), "contacted_at": .string(ISO8601DateFormatter().string(from: contactedAt))]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["note"] = .string(trimmed) }
        if setFollowUp { body["follow_up_at"] = .string(saDayString(followUp)) }
        do { _ = try await api.request("admin/user-analytics/\(userID)/outreach", method: "POST", body: body); dismiss() }
        catch { self.error = error.localizedDescription }
        saving = false
    }
}

struct SARelationshipForm: View {
    @ObservedObject var store: SuperAdminPortalStore
    let userID: String
    let relationship: SAValue
    let owners: [SAValue]
    @Environment(\.dismiss) private var dismiss
    @State private var stage = ""
    @State private var owner = ""
    @State private var hasFollowUp = false
    @State private var followUp = Date()
    @State private var note = ""
    @State private var isInternal = false
    @State private var saving = false
    @State private var error: String?
    @State private var initial: [String: SAValue] = [:]
    var body: some View {
        NavigationStack {
            Form {
                Picker("Stage", selection: $stage) {
                    Text("Not set").tag("")
                    ForEach(SAUserStage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Owner", selection: $owner) {
                    Text("Nobody").tag("")
                    ForEach(owners, id: \.recordID) { person in Text(person["email"].text).tag(person.recordID) }
                    // An owner who is no longer a super admin still shows, so the form isn't blank.
                    if !owner.isEmpty && !owners.contains(where: { $0.recordID == owner }) {
                        Text(relationship["owner"]["email"].text.isEmpty ? "Former owner" : relationship["owner"]["email"].text).tag(owner)
                    }
                }
                Section {
                    Toggle("Follow-up date", isOn: $hasFollowUp)
                    if hasFollowUp { DatePicker("Follow up on", selection: $followUp, displayedComponents: .date) }
                }
                Section("Note") { TextField("Context for the team", text: $note, axis: .vertical).lineLimit(3...8) }
                Section {
                    Toggle("Internal or test account", isOn: $isInternal)
                } footer: { Text("Internal accounts are hidden from the default list and never appear in the inactivity digest.") }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Relationship").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving || note.count > 2000) }
            }
            .onAppear {
                stage = relationship["stage"].text
                owner = relationship["owner"]["id"].text
                note = relationship["note"].text
                isInternal = relationship["is_internal"].flag
                if let day = saDayDate(relationship["follow_up_at"].text) { hasFollowUp = true; followUp = day }
                initial = values
            }
        }
    }
    private var values: [String: SAValue] {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "stage": stage.isEmpty ? .null : .string(stage),
            "owner_user_id": owner.isEmpty ? .null : .string(owner),
            "follow_up_at": hasFollowUp ? .string(saDayString(followUp)) : .null,
            "note": trimmed.isEmpty ? .null : .string(trimmed),
            "is_internal": .bool(isInternal),
        ]
    }
    private func save() async {
        guard let api = store.api else { return }
        // Only what changed here, so another admin's edits to other fields are kept.
        let body = values.filter { initial[$0.key] != $0.value }
        if body.isEmpty { dismiss(); return }
        saving = true; error = nil
        do { _ = try await api.request("admin/user-analytics/\(userID)/relationship", method: "PUT", body: body); dismiss() }
        catch { self.error = error.localizedDescription }
        saving = false
    }
}

/// Calendar day in the phone's time zone, as the server's YYYY-MM-DD.
func saDayString(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}
func saDayDate(_ text: String) -> Date? {
    let parts = text.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
}

/// Body of an inactivity digest alert: the people in it, each opening their page.
struct SAInactivityAlertSections: View {
    @ObservedObject var store: SuperAdminPortalStore
    let details: SAValue
    var body: some View {
        section("Not used Talia for 2+ days", details["inactive"].array)
        section("Follow-ups due", details["follow_ups"].array)
        Section { Button("Open Users") { store.selectedTab = 4 } }
    }
    @ViewBuilder private func section(_ title: String, _ people: [SAValue]) -> some View {
        if !people.isEmpty {
            Section(title) {
                ForEach(people, id: \.recordID) { person in
                    let name = person["name"].text.isEmpty ? person["email"].text : person["name"].text
                    NavigationLink { SAUserAnalyticsView(store: store, userID: person.recordID, title: name) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.body.weight(.semibold))
                            Text("\(person["tenant"].text) · \(person["reason"].text)").font(.subheadline).foregroundStyle(.secondary)
                            Text(person["last_outreach_at"].isNull ? "Never contacted" : "Last contacted \(String(person["last_outreach_at"].text.prefix(10)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
