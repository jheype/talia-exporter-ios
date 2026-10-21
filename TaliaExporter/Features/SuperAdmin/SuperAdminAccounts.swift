import SwiftUI

/// Accounts: prospects and tenants, who to follow up with today, their stage and notes.
/// Server: /api/admin/accounts (super admin + verified MFA).
enum SAAccountView: String, CaseIterable, Identifiable {
    case followUp = "follow_up", upcoming, prospects, onboarding, customers, closed, all, internalOnly = "internal"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .followUp: "Follow up"
        case .upcoming: "Scheduled"
        case .prospects: "Prospects"
        case .onboarding: "Onboarding"
        case .customers: "Customers"
        case .closed: "Closed"
        case .all: "All"
        case .internalOnly: "Internal"
        }
    }
}

/// One lifecycle from first contact to leaving, in the server's order.
let saAccountStages: [(String, String)] = [
    ("lead", "Lead"), ("contacted", "Contacted"), ("demo", "Demo"), ("invited", "Invited"), ("onboarding", "Onboarding"),
    ("customer", "Customer"), ("at_risk", "At risk"), ("churned", "Churned"), ("lost", "Lost"),
]
let saAccountWarmth: [(String, String)] = [("champion", "Champion"), ("warm", "Warm"), ("neutral", "Neutral"), ("cold", "Cold"), ("do_not_contact", "Do not contact")]
let saUpdateTypes: [(String, String)] = saOutreachChannels + [("note", "Note")]

func saStageColor(_ stage: String) -> Color {
    switch stage {
    case "lead", "contacted", "demo": .blue
    case "invited", "onboarding": .purple
    case "customer": .green
    case "at_risk": .orange
    case "churned": .red
    default: .secondary
    }
}

struct SAStageBadge: View {
    let stage: String
    var body: some View {
        Text(saChoiceTitle(saAccountStages, stage))
            .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(saStageColor(stage)).background(saStageColor(stage).opacity(0.14), in: Capsule())
    }
}

/// When to follow up next, as offered after a contact.
enum SAFollowUpChoice: String, CaseIterable, Identifiable {
    case keep, tomorrow, threeDays, week, twoWeeks, month, date, none
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .tomorrow: 1
        case .threeDays: 3
        case .week: 7
        case .twoWeeks: 14
        case .month: 30
        default: nil
        }
    }
    func title(keeping current: Date?, due: Bool = false) -> String {
        switch self {
        case .keep: due ? "Keep it due" : current.map { "Keep \($0.formatted(.dateTime.day().month()))" } ?? "No change"
        case .tomorrow: "Tomorrow"
        case .threeDays: "In 3 days"
        case .week: "In a week"
        case .twoWeeks: "In 2 weeks"
        case .month: "In a month"
        case .date: "Pick a date"
        case .none: "No follow-up"
        }
    }
}

/// The follow_up_at to send: nil leaves it to the server (a later date is kept,
/// a due one is done once they are reached); `.null` clears it.
func saFollowUpValue(_ choice: SAFollowUpChoice, picked: Date, today: Date = Date()) -> SAValue? {
    switch choice {
    case .keep: return nil
    case .none: return .null
    case .date: return .string(saDayString(picked))
    default:
        let day = Calendar.current.date(byAdding: .day, value: choice.days ?? 0, to: today) ?? today
        return .string(saDayString(day))
    }
}

/// Keep is offered for a follow-up still to come, with a note, and after no
/// answer (a due one stays due); a due one is otherwise done once they are reached.
func saFollowUpChoices(current: String, isNote: Bool, noAnswer: Bool = false, today: Date = Date()) -> [SAFollowUpChoice] {
    let future = saDayDate(current).map { saDayString($0) > saDayString(today) } ?? false
    let booked = saDayDate(current) != nil
    return SAFollowUpChoice.allCases.filter { $0 != .keep || future || isNote || (noAnswer && booked) }
}
/// What "Next follow-up" starts on: after no answer, try again rather than push it a week out.
func saDefaultFollowUp(current: String, isNote: Bool, outcome: String, today: Date = Date()) -> SAFollowUpChoice {
    if isNote { return .keep }
    if outcome == "no_answer" { return saDayDate(current) == nil ? .tomorrow : .keep }
    return saFollowUpChoices(current: current, isNote: false, today: today).contains(.keep) ? .keep : .week
}

/// "14:30", 24-hour, from the phone's clock (the server reads it as UK time).
func saTimeString(_ date: Date) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}
func saTimeDate(_ text: String, on day: Date = Date()) -> Date? {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
}
/// "Thu 23 Oct at 14:30 · Call Jo"
func saFollowUpText(_ account: SAValue) -> String? {
    guard let day = saDayDate(account["follow_up_at"].text) else { return nil }
    let time = account["follow_up_time"].text, step = account["next_step"].text
    return day.formatted(.dateTime.weekday(.abbreviated).day().month()) + (time.isEmpty ? "" : " at \(time)") + (step.isEmpty ? "" : " · \(step)")
}

/// Reasons first, then the next follow-up.
func saAccountNextLine(_ account: SAValue) -> (text: String, due: Bool) {
    let reasons = account["reasons"].array.map { $0["label"].text }
    if !reasons.isEmpty { return (reasons.joined(separator: " · "), true) }
    if let text = saFollowUpText(account) { return (text, false) }
    return ("No follow-up", false)
}

struct SAAccountsView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @State private var view: SAAccountView = .followUp
    @State private var query = ""
    @State private var response: SAValue = .null
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var adding = false
    @State private var opened: String?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SAAccountView.allCases) { item in
                            let count = response["counts"][item.rawValue].text
                            Button(count.isEmpty ? item.title : "\(item.title) · \(count)") { view = item }
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                .background(view == item ? Color.taliaAccent : Color.taliaSecondaryBackground, in: Capsule())
                                .foregroundStyle(view == item ? Color.taliaOnAccent : Color.taliaAccent)
                                .accessibilityAddTraits(view == item ? .isSelected : [])
                                .buttonStyle(.plain)
                        }
                    }
                }
            }.listRowBackground(Color.clear)
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } } }
            if loading && response.isNull { ProgressView("Loading accounts…") }
            Section {
                ForEach(response["items"].array, id: \.recordID) { account in
                    NavigationLink { SAAccountDetailView(store: store, accountID: account.recordID, title: account["name"].text) } label: { row(account) }
                        .listRowBackground(Color.taliaSecondaryBackground)
                }
            }
            if !loading && error == nil && !response.isNull && response["items"].array.isEmpty {
                ContentUnavailableView(view == .followUp ? "All caught up" : "No accounts", systemImage: view == .followUp ? "checkmark.circle" : "building.2",
                                       description: Text(view == .followUp ? "Nobody to follow up with right now." : "No accounts match this view."))
            }
            Section {} footer: {
                Text("Follow up lists due follow-ups, and accounts Talia thinks need a call: an invite nobody has used for 3 days, a tenant quiet for 7 days, a trial ending, a failed payment, a cancellation or downgrade, or a prospect with no next step. A check-in is booked 5 days after a tenant first signs in.")
            }
        }.taliaSurface().navigationTitle("Accounts")
        .searchable(text: $query, prompt: "Company, contact, email or phone")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: query) { _, value in if value.isEmpty { Task { await load() } } }
        .onChange(of: view) { _, _ in Task { await load() } }
        .toolbar {
            NavigationLink { SAAccountsCalendarView(store: store) } label: { Image(systemName: "calendar") }.accessibilityLabel("Calendar")
            Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add prospect")
        }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            SAProspectForm(store: store) { id in opened = id }
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })) {
            if let opened { SAAccountDetailView(store: store, accountID: opened, title: "Account").id(opened) }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ account: SAValue) -> some View {
        let next = saAccountNextLine(account)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(account["name"].text).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                SAStageBadge(stage: account["stage"].text)
            }
            Text(next.text).font(.subheadline).foregroundStyle(next.due ? Color.orange : .secondary).lineLimit(2)
            HStack(spacing: 10) {
                if account["type"].text == "prospect" { Label("Prospect", systemImage: "person.crop.circle.badge.questionmark") }
                let contact = account["last_contact"]
                if let at = saDate(contact["at"].text) {
                    Text("\(saChoiceTitle(saOutreachChannels, contact["channel"].text)) \(at.formatted(date: .abbreviated, time: .omitted))")
                } else { Text("Never contacted") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func load() async {
        guard let api = store.api else { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let scope = store.sessionRevision
        var components = URLComponents()
        components.queryItems = [.init(name: "view", value: view.rawValue)]
        if !query.isEmpty { components.queryItems?.append(.init(name: "q", value: query)) }
        let encoded = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        do {
            let result = try await api.request("admin/accounts?" + encoded)
            guard generation == current, scope == store.sessionRevision, !Task.isCancelled else { return }
            if result["items"].isNull { throw SARequestError(status: 502, code: "CONTRACT", message: "The server response has changed. Refresh or update the app.") }
            response = result
        } catch {
            if generation == current && scope == store.sessionRevision && !Task.isCancelled && !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if generation == current { loading = false }
    }
}

struct SAAccountDetailView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let accountID: String
    let title: String
    @State private var detail: SAValue = .null
    @State private var meta: SAValue = .null
    @State private var loading = false
    @State private var error: String?
    @State private var logging = false
    @State private var editing = false
    @State private var generation = UUID()
    @State private var pendingDelete: SAValue?
    @State private var deleted = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismissPage

    private var account: SAValue { detail["account"] }
    var body: some View {
        List {
            if loading && detail.isNull { ProgressView("Loading account…") }
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load() } } } }
            if !detail.isNull { content }
        }.taliaSurface().navigationTitle(account["name"].text.isEmpty ? title : account["name"].text).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Log an update", systemImage: "phone.arrow.up.right") { logging = true }
                Button("Edit account", systemImage: "square.and.pencil") { editing = true }
            } label: { Image(systemName: "plus") }.disabled(detail.isNull)
        }
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog("Delete this entry? This can't be undone.", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.recordID { Task { await deleteEntry(id) } }
                pendingDelete = nil
            }
        }
        .sheet(isPresented: $logging, onDismiss: { Task { await load() } }) {
            SAAccountUpdateForm(store: store, account: account, people: detail["people"].array.filter { !$0["is_internal"].flag })
        }
        .sheet(isPresented: $editing, onDismiss: { if deleted { dismissPage() } else { Task { await load() } } }) {
            SAAccountEditForm(store: store, account: account, owners: meta["owners"].array) { deleted = true }
        }
    }

    @ViewBuilder private var content: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SAStageBadge(stage: account["stage"].text)
                    if !account["warmth"].isNull { Text(saChoiceTitle(saAccountWarmth, account["warmth"].text)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(account["type"].text == "prospect" ? "Prospect" : "Tenant").font(.caption).foregroundStyle(.secondary)
                }
                let tenant = account["tenant"]
                if !tenant.isNull {
                    Text([saLabel(tenant["plan"].text), saLabel(tenant["status"].text), "\(tenant["user_count"].text) users"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                } else { Text("Not on Talia yet").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(.vertical, 4)
            if !account["reasons"].array.isEmpty {
                Label(account["reasons"].array.map { $0["label"].text }.joined(separator: " · "), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Next follow-up", value: saFollowUpText(account) ?? "None")
            LabeledContent("Owner", value: account["owner"]["email"].text.isEmpty ? "Nobody" : account["owner"]["email"].text)
            Button { logging = true } label: { Label("Log an update", systemImage: "phone.arrow.up.right") }
        }
        Section("Contact") {
            let contact = account["contact"]
            if !contact["name"].text.isEmpty { Text(contact["name"].text) }
            if !contact["phone"].text.isEmpty {
                Button { if let url = URL(string: "tel:" + contact["phone"].text.filter { "+0123456789".contains($0) }) { openURL(url) } } label: { Label(contact["phone"].text, systemImage: "phone") }
                Button {
                    let digits = contact["phone"].text.filter { "0123456789".contains($0) }
                    if let url = URL(string: "https://wa.me/\(digits)") { openURL(url) }
                } label: { Label("WhatsApp", systemImage: "message") }
            }
            if !contact["email"].text.isEmpty {
                Button { if let url = URL(string: "mailto:" + contact["email"].text) { openURL(url) } } label: { Label(contact["email"].text, systemImage: "envelope") }
            }
            if contact["name"].text.isEmpty && contact["phone"].text.isEmpty && contact["email"].text.isEmpty {
                Text("No contact details. Add them with Edit account.").foregroundStyle(.secondary)
            }
        }
        if !account["note"].text.isEmpty { Section("Notes") { Text(account["note"].text).font(.subheadline).textSelection(.enabled) } }
        if !account["tenant"].isNull {
            Section("People") {
                if let first = saDate(account["first_sign_in_at"].text) { LabeledContent("First sign-in", value: first.formatted(date: .abbreviated, time: .omitted)) }
                if let last = saDate(account["last_activity_at"].text) { LabeledContent("Last used Talia", value: last.formatted(date: .abbreviated, time: .omitted)) }
                ForEach(detail["people"].array.filter { !$0["is_internal"].flag }, id: \.recordID) { person in
                    NavigationLink { SAUserAnalyticsView(store: store, userID: person.recordID, title: person["name"].text.isEmpty ? person["email"].text : person["name"].text) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person["name"].text.isEmpty ? person["email"].text : person["name"].text)
                            Text(person["signed_in"].flag ? person["email"].text : "\(person["email"].text) · not signed in yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section("Timeline") {
            if detail["timeline"].array.isEmpty { Text("Nothing yet. Log your first contact.").foregroundStyle(.secondary) }
            ForEach(detail["timeline"].array, id: \.recordID) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(describe(entry)).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let at = saDate(entry["at"].text) { Text(at.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    }
                    let kind = entry["kind"].text
                    if (kind == "contact" || kind == "note") && !entry["note"].text.isEmpty { Text(entry["note"].text).font(.subheadline) }
                    let by = entry["by"].text.isEmpty ? (kind == "stage" || kind == "event" ? "Talia" : "Team member") : entry["by"].text
                    Text(kind == "stage" && !entry["note"].text.isEmpty ? "\(by) · \(entry["note"].text)" : by).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions(allowsFullSwipe: false) {
                    if entry["can_delete"].flag { Button("Delete", role: .destructive) { pendingDelete = entry } }
                }
            }
        }
    }

    private func describe(_ entry: SAValue) -> String {
        switch entry["kind"].text {
        case "contact":
            let with = entry["with"]
            let who = with.isNull ? "" : " with \(with["name"].text.isEmpty ? with["email"].text : with["name"].text)"
            return "\(saChoiceTitle(saOutreachChannels, entry["channel"].text)) · \(saChoiceTitle(saOutreachOutcomes, entry["outcome"].text))\(who)"
        case "note": return "Note"
        case "stage":
            let to = saChoiceTitle(saAccountStages, entry["to_stage"].text)
            return entry["from_stage"].isNull ? "Stage: \(to)" : "Stage: \(saChoiceTitle(saAccountStages, entry["from_stage"].text)) → \(to)"
        default: return entry["note"].text.isEmpty ? saLabel(entry["event"].text) : entry["note"].text
        }
    }

    private func load() async {
        guard let api = store.api, UUID(uuidString: accountID) != nil else { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let scope = store.sessionRevision
        do {
            let value = try await api.request("admin/accounts/\(accountID)")
            guard generation == current, scope == store.sessionRevision, !Task.isCancelled else { return }
            detail = value
            if meta.isNull, let loaded = try? await api.request("admin/accounts/meta"), scope == store.sessionRevision { meta = loaded }
        } catch {
            if generation == current && scope == store.sessionRevision && !(error is CancellationError) { self.error = error.localizedDescription }
        }
        if generation == current { loading = false }
    }

    private func deleteEntry(_ id: String) async {
        guard let api = store.api, UUID(uuidString: id) != nil else { return }
        do { _ = try await api.request("admin/accounts/\(accountID)/activity/\(id)", method: "DELETE"); await load() }
        catch { self.error = error.localizedDescription }
    }
}

/// Log a call, WhatsApp, email, meeting or note, and in the same step the next follow-up and stage.
struct SAAccountUpdateForm: View {
    @ObservedObject var store: SuperAdminPortalStore
    let account: SAValue
    let people: [SAValue]
    @Environment(\.dismiss) private var dismiss
    @State private var type = "call"
    @State private var outcome = "reached"
    @State private var person = ""
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var followUp: SAFollowUpChoice = .week
    @State private var picked = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var nextStep = ""
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var followUpChosen = false
    @State private var stage = ""
    @State private var saving = false
    @State private var error: String?

    private var isNote: Bool { type == "note" }
    private var current: String { account["follow_up_at"].text }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) { ForEach(saUpdateTypes, id: \.0) { Text($0.1).tag($0.0) } }
                if !isNote {
                    Picker("Outcome", selection: $outcome) { ForEach(saOutreachOutcomes, id: \.0) { Text($0.1).tag($0.0) } }
                    if !people.isEmpty {
                        Picker("With", selection: $person) {
                            Text("The company").tag("")
                            ForEach(people, id: \.recordID) { p in Text(p["name"].text.isEmpty ? p["email"].text : p["name"].text).tag(p.recordID) }
                        }
                    }
                }
                DatePicker("When", selection: $occurredAt, in: ...Date())
                Section(isNote ? "Note" : "Note (optional)") { TextField(isNote ? "Anything worth remembering" : "What was said, what they need", text: $note, axis: .vertical).lineLimit(3...8) }
                Section("Next follow-up") {
                    Picker("Follow up", selection: Binding(get: { followUp }, set: { followUp = $0; followUpChosen = true })) {
                        let due = saDayDate(current).map { saDayString($0) <= saDayString(Date()) } ?? false
                        ForEach(saFollowUpChoices(current: current, isNote: isNote, noAnswer: outcome == "no_answer")) {
                            Text($0.title(keeping: saDayDate(current), due: due && !isNote)).tag($0)
                        }
                    }
                    if followUp == .date { DatePicker("On", selection: $picked, in: Date()..., displayedComponents: .date) }
                    if followUp != .keep && followUp != .none {
                        Toggle("Book a time", isOn: $hasTime)
                        if hasTime { DatePicker("Time (UK)", selection: $time, displayedComponents: .hourAndMinute) }
                        TextField("Next step (optional)", text: $nextStep)
                    }
                }
                Section("Stage") {
                    Picker("Stage", selection: $stage) {
                        let currentStage = account["stage"].text
                        Text(currentStage == "lead" && !isNote && outcome != "no_answer" ? "Move to Contacted" : "Keep \(saChoiceTitle(saAccountStages, currentStage))").tag("")
                        ForEach(saAccountStages.filter { $0.0 != currentStage }, id: \.0) { Text("Move to \($0.1)").tag($0.0) }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle(account["name"].text).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || note.count > 2000 || nextStep.count > 200 || (isNote && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .onAppear { followUp = saDefaultFollowUp(current: current, isNote: false, outcome: outcome) }
            .onChange(of: type) { _, value in refreshFollowUp(isNote: value == "note", outcome: outcome) }
            .onChange(of: outcome) { _, value in refreshFollowUp(isNote: isNote, outcome: value) }
        }
    }
    /// A follow-up the tester picked is kept while it is still offered;
    /// otherwise the default for the new type and outcome applies.
    private func refreshFollowUp(isNote: Bool, outcome: String) {
        let offered = saFollowUpChoices(current: current, isNote: isNote, noAnswer: outcome == "no_answer")
        if followUpChosen && offered.contains(followUp) { return }
        followUp = saDefaultFollowUp(current: current, isNote: isNote, outcome: outcome)
        followUpChosen = false
    }
    private func save() async {
        guard let api = store.api, UUID(uuidString: account.recordID) != nil else { return }
        saving = true; error = nil
        var body: [String: SAValue] = ["kind": .string(isNote ? "note" : "contact"), "occurred_at": .string(ISO8601DateFormatter().string(from: occurredAt))]
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["note"] = .string(trimmed) }
        if !isNote {
            body["channel"] = .string(type); body["outcome"] = .string(outcome)
            if !person.isEmpty { body["user_id"] = .string(person) }
        }
        if let value = saFollowUpValue(followUp, picked: picked) {
            body["follow_up_at"] = value
            let step = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != .null && !step.isEmpty { body["next_step"] = .string(step) }
            if value != .null && hasTime { body["follow_up_time"] = .string(saTimeString(time)) }
        }
        if !stage.isEmpty { body["stage"] = .string(stage) }
        do { _ = try await api.request("admin/accounts/\(account.recordID)/activity", method: "POST", body: body); dismiss() }
        catch { self.error = error.localizedDescription }
        saving = false
    }
}

struct SAAccountEditForm: View {
    @ObservedObject var store: SuperAdminPortalStore
    let account: SAValue
    let owners: [SAValue]
    /// The prospect was deleted: the page behind this sheet has nothing to show.
    var onDeleted: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var stage = ""
    @State private var warmth = ""
    @State private var owner = ""
    @State private var hasFollowUp = false
    @State private var followUp = Date()
    @State private var nextStep = ""
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var note = ""
    @State private var contactName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var isInternal = false
    @State private var saving = false
    @State private var deleting = false
    @State private var error: String?
    @State private var initial: [String: SAValue] = [:]

    private var isProspect: Bool { account["type"].text == "prospect" }
    var body: some View {
        NavigationStack {
            Form {
                if isProspect { TextField("Company", text: $name) }
                Picker("Stage", selection: $stage) { ForEach(saAccountStages, id: \.0) { Text($0.1).tag($0.0) } }
                Picker("Warmth", selection: $warmth) {
                    Text("Not set").tag("")
                    ForEach(saAccountWarmth, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Owner", selection: $owner) {
                    Text("Nobody").tag("")
                    ForEach(owners, id: \.recordID) { person in Text(person["email"].text).tag(person.recordID) }
                    if !owner.isEmpty && !owners.contains(where: { $0.recordID == owner }) {
                        Text(account["owner"]["email"].text.isEmpty ? "Former owner" : account["owner"]["email"].text).tag(owner)
                    }
                }
                Section {
                    Toggle("Follow-up date", isOn: $hasFollowUp)
                    if hasFollowUp {
                        DatePicker("Follow up on", selection: $followUp, displayedComponents: .date)
                        Toggle("Book a time", isOn: $hasTime)
                        if hasTime { DatePicker("Time (UK)", selection: $time, displayedComponents: .hourAndMinute) }
                        TextField("Next step (optional)", text: $nextStep)
                    }
                }
                Section("Contact") {
                    TextField("Name", text: $contactName)
                    TextField("Phone or WhatsApp", text: $phone).keyboardType(.phonePad)
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Notes") { TextField("What they deal in, who decides, anything to remember", text: $note, axis: .vertical).lineLimit(3...8) }
                if !isProspect {
                    Section {
                        Toggle("Internal or test account", isOn: $isInternal)
                    } footer: { Text("Internal accounts are hidden from the lists and never in the follow-up digest.") }
                } else {
                    Section { Button("Delete prospect", role: .destructive) { deleting = true } }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Edit account").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || note.count > 2000 || nextStep.count > 200 || (isProspect && name.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .confirmationDialog("Delete this prospect and its timeline? This can't be undone.", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await deleteProspect() } }
            }
            .onAppear {
                name = account["name"].text
                stage = account["stage"].text
                warmth = account["warmth"].text
                owner = account["owner"]["id"].text
                if let day = saDayDate(account["follow_up_at"].text) { hasFollowUp = true; followUp = day }
                if let at = saTimeDate(account["follow_up_time"].text) { hasTime = true; time = at }
                nextStep = account["next_step"].text
                note = account["note"].text
                contactName = account["contact"]["name"].text
                phone = account["contact"]["phone"].text
                email = account["contact"]["email"].text
                isInternal = account["is_internal"].flag
                initial = values
            }
        }
    }
    private var values: [String: SAValue] {
        func text(_ value: String) -> SAValue {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .null : .string(trimmed)
        }
        var result: [String: SAValue] = [
            "stage": .string(stage),
            "warmth": warmth.isEmpty ? .null : .string(warmth),
            "owner_user_id": owner.isEmpty ? .null : .string(owner),
            "follow_up_at": hasFollowUp ? .string(saDayString(followUp)) : .null,
            "follow_up_time": hasFollowUp && hasTime ? .string(saTimeString(time)) : .null,
            "next_step": hasFollowUp ? text(nextStep) : .null,
            "note": text(note),
            "contact_name": text(contactName),
            "contact_phone": text(phone),
            "contact_email": text(email),
        ]
        if isProspect { result["name"] = text(name) } else { result["is_internal"] = .bool(isInternal) }
        return result
    }
    private func save() async {
        guard let api = store.api, UUID(uuidString: account.recordID) != nil else { return }
        // Only what changed here, so another admin's edits to other fields are kept.
        var body = values.filter { initial[$0.key] != $0.value }
        if body.isEmpty { dismiss(); return }
        // The server reads a date and its time together.
        if body["follow_up_at"] != nil || body["follow_up_time"] != nil {
            body["follow_up_at"] = values["follow_up_at"]; body["follow_up_time"] = values["follow_up_time"]
        }
        saving = true; error = nil
        do { _ = try await api.request("admin/accounts/\(account.recordID)", method: "PATCH", body: body); dismiss() }
        catch { self.error = error.localizedDescription }
        saving = false
    }
    private func deleteProspect() async {
        guard let api = store.api, UUID(uuidString: account.recordID) != nil else { return }
        do { _ = try await api.request("admin/accounts/\(account.recordID)", method: "DELETE"); onDeleted(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// A company to chase before they have a Talia account.
struct SAProspectForm: View {
    @ObservedObject var store: SuperAdminPortalStore
    var onCreated: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var contactName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var stage = "lead"
    @State private var followUp: SAFollowUpChoice = .tomorrow
    @State private var picked = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var nextStep = ""
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var note = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Company", text: $name)
                Section {
                    TextField("Contact name", text: $contactName)
                    TextField("Phone or WhatsApp", text: $phone).keyboardType(.phonePad)
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("Once they sign up to Talia with this email, their account joins this record.") }
                Picker("Stage", selection: $stage) { ForEach(saAccountStages.prefix(3), id: \.0) { Text($0.1).tag($0.0) } }
                Section("First follow-up") {
                    Picker("Follow up", selection: $followUp) {
                        ForEach(SAFollowUpChoice.allCases.filter { $0 != .keep }) { Text($0.title(keeping: nil)).tag($0) }
                    }
                    if followUp == .date { DatePicker("On", selection: $picked, in: Date()..., displayedComponents: .date) }
                    if followUp != .none {
                        Toggle("Book a time", isOn: $hasTime)
                        if hasTime { DatePicker("Time (UK)", selection: $time, displayedComponents: .hourAndMinute) }
                        TextField("Next step (optional)", text: $nextStep)
                    }
                }
                Section("Notes") { TextField("Where you met, what they deal in, what they need", text: $note, axis: .vertical).lineLimit(3...8) }
                if let error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Add prospect").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }.disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || note.count > 2000)
                }
            }
        }
    }
    private func save() async {
        guard let api = store.api else { return }
        saving = true; error = nil
        func text(_ value: String) -> SAValue? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .string(trimmed)
        }
        var body: [String: SAValue] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "stage": .string(stage)]
        body["contact_name"] = text(contactName); body["contact_phone"] = text(phone); body["contact_email"] = text(email); body["note"] = text(note)
        if let value = saFollowUpValue(followUp, picked: picked), value != .null {
            body["follow_up_at"] = value
            body["next_step"] = text(nextStep)
            if hasTime { body["follow_up_time"] = .string(saTimeString(time)) }
        }
        do {
            let created = try await api.request("admin/accounts", method: "POST", body: body)
            let id = created["account"]["id"].text
            dismiss()
            if !id.isEmpty { onCreated(id) }
        } catch { self.error = error.localizedDescription }
        saving = false
    }
}

/// One calendar entry: a follow-up (with any call time), a trial end or a scheduled cancellation.
struct SACalendarEventRow: View {
    @ObservedObject var store: SuperAdminPortalStore
    let event: SAValue
    var showDay = false
    var body: some View {
        NavigationLink { SAAccountDetailView(store: store, accountID: event["account"]["id"].text, title: event["account"]["name"].text) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if showDay, let day = saDayDate(event["date"].text) { Text(day.formatted(.dateTime.weekday(.abbreviated).day())).font(.caption2).foregroundStyle(.secondary) }
                    Text(event["time"].isNull ? (event["overdue"].flag ? "Late" : "All day") : event["time"].text).font(.caption.monospacedDigit())
                        .foregroundStyle(event["overdue"].flag ? Color.orange : .secondary)
                }.frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event["account"]["name"].text).font(.body.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(event["kind"].text == "cancels" ? Color.red : .secondary).lineLimit(2)
                }
            }
        }
    }
    private var detail: String {
        switch event["kind"].text {
        case "trial_ends": return "Trial ends"
        case "cancels": return "Plan cancels"
        default:
            let due = saDayDate(event["due_date"].text).map { " · was due \($0.formatted(.dateTime.day().month()))" } ?? ""
            return event["label"].text + (event["overdue"].flag ? due : "")
        }
    }
}

/// Follow-ups and calls by day, with trial ends and cancellations.
struct SAAccountsCalendarView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @State private var day = Date()
    @State private var month: SAValue = .null
    @State private var loadedMonth = ""
    @State private var error: String?
    @State private var generation = UUID()

    private var monthKey: String { String(saDayString(day).prefix(7)) }
    private var events: [SAValue] { month["events"].array }
    var body: some View {
        List {
            Section { DatePicker("Day", selection: $day, displayedComponents: .date).datePickerStyle(.graphical) }
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load(force: true) } } } }
            Section(Calendar.current.isDateInToday(day) ? "Today" : day.formatted(date: .complete, time: .omitted)) {
                let todays = events.filter { $0["date"].text == saDayString(day) }
                if todays.isEmpty { Text(month.isNull ? "Loading…" : "Nothing scheduled.").foregroundStyle(.secondary) }
                ForEach(Array(todays.enumerated()), id: \.offset) { _, event in SACalendarEventRow(store: store, event: event) }
            }
            let busy = Dictionary(grouping: events, by: { $0["date"].text }).sorted { $0.key < $1.key }
            if !busy.isEmpty {
                Section("Booked this month") {
                    ForEach(busy, id: \.key) { date, items in
                        Button {
                            if let picked = saDayDate(date) { day = picked }
                        } label: {
                            HStack {
                                Text(saDayDate(date)?.formatted(.dateTime.weekday(.abbreviated).day().month()) ?? date)
                                Spacer()
                                Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.foregroundStyle(saDayString(day) == date ? Color.taliaAccent : .primary)
                    }
                }
            }
        }.taliaSurface().navigationTitle("Calendar").navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(force: true) }
        .task(id: monthKey) { await load(force: false) }
        // Back from an account page: what was edited there shows at once.
        .onAppear { if !loadedMonth.isEmpty { Task { await load(force: true) } } }
    }

    private func load(force: Bool) async {
        guard let api = store.api, force || loadedMonth != monthKey else { return }
        let current = UUID(); generation = current; error = nil
        let scope = store.sessionRevision, key = monthKey
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let first = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let last = Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: first) else { return }
        do {
            let result = try await api.request("admin/accounts/calendar?from=\(saDayString(first))&to=\(saDayString(last))")
            guard generation == current, scope == store.sessionRevision, !Task.isCancelled else { return }
            if result["events"].isNull { throw SARequestError(status: 502, code: "CONTRACT", message: "The server response has changed. Refresh or update the app.") }
            month = result; loadedMonth = key
        } catch {
            if generation == current && scope == store.sessionRevision && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}

/// Home card: who to reach out to today and what is booked.
struct SAYourDayCard: View {
    @ObservedObject var store: SuperAdminPortalStore
    let revision: Int
    @State private var due: SAValue = .null
    @State private var week: SAValue = .null
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your day").font(.headline)
                Spacer()
                Button("Accounts") { store.selectedTab = 5 }.font(.subheadline)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            let reach = due["items"].array
            Text(due.isNull ? "Reach out" : "Reach out · \(due["counts"]["follow_up"].text)").font(.subheadline.weight(.semibold))
            if !due.isNull && reach.isEmpty { Text("Nobody to follow up with right now.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(reach.prefix(5), id: \.recordID) { account in
                NavigationLink { SAAccountDetailView(store: store, accountID: account.recordID, title: account["name"].text) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account["name"].text).font(.body.weight(.semibold)).lineLimit(1)
                            Text(account["reasons"].array.map { $0["label"].text }.joined(separator: " · ")).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                        Spacer()
                        SAStageBadge(stage: account["stage"].text)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if reach.count > 5 { Button("See all \(reach.count)") { store.selectedTab = 5 }.font(.footnote) }
            Divider()
            let today = saDayString(Date())
            let todays = week["events"].array.filter { $0["date"].text == today }
            Text(todays.isEmpty ? "Scheduled today" : "Scheduled today · \(todays.count)").font(.subheadline.weight(.semibold))
            if !week.isNull && todays.isEmpty { Text("No calls or follow-ups booked for today.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(Array(todays.enumerated()), id: \.offset) { _, event in SACalendarEventRow(store: store, event: event).buttonStyle(.plain) }
            let later = week["events"].array.filter { $0["date"].text > today }
            if !later.isEmpty {
                Text("Next 6 days · \(later.count)").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(later.prefix(4).enumerated()), id: \.offset) { _, event in SACalendarEventRow(store: store, event: event, showDay: true).buttonStyle(.plain) }
            }
            NavigationLink { SAAccountsCalendarView(store: store) } label: { Label("Open calendar", systemImage: "calendar").font(.subheadline.weight(.semibold)) }
        }.taliaCard()
        .task(id: revision) { await load() }
    }

    private func load() async {
        guard let api = store.api else { return }
        let scope = store.sessionRevision
        let today = Date(), end = Calendar.current.date(byAdding: .day, value: 6, to: Date()) ?? Date()
        do {
            let loadedDue = try await api.request("admin/accounts?view=follow_up")
            let loadedWeek = try await api.request("admin/accounts/calendar?from=\(saDayString(today))&to=\(saDayString(end))")
            guard scope == store.sessionRevision else { return }
            due = loadedDue; week = loadedWeek; error = nil
        } catch {
            if scope == store.sessionRevision && !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
}
