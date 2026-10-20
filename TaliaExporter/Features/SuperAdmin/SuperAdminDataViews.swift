import SwiftUI
import Charts

struct SASectionView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let section: SuperAdminSection
    @State private var selected = 0
    @State private var action: SAAction?
    @State private var revision = UUID()
    var body: some View {
        VStack(spacing: 0) {
            if section.datasets.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(section.datasets.enumerated()), id: \.offset) { index, item in
                            Button(item.title) { selected = index }
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 10)
                                .background(selected == index ? Color.taliaAccent : Color.taliaSecondaryBackground, in: Capsule())
                                .foregroundStyle(selected == index ? Color.taliaOnAccent : Color.taliaAccent)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            if section == .overview && selected == 0 { SAOverviewView(store: store) }
            else if section.datasets.indices.contains(selected) {
                SADatasetView(store: store, dataset: section.datasets[selected]).id("\(selected)-\(revision)")
            }
        }.background(Color.taliaBackground).navigationTitle(section.title)
        .toolbar {
            if section == .tenants {
                Menu {
                    Button("Create company") { action = SAAction.createTenant }
                    Button("Generate signup link") { action = SAAction.signupLink }
                    Button("Generate Price Intel signup link") { action = .init("Price Intel signup link", "admin/invitations/generate-signup-link", body: ["plan_tier": .string("price_intel")]) }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $action, onDismiss: { revision = UUID() }) { action in SAActionView(store: store, action: action) {} }
    }
}

struct SADatasetView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let dataset: SADataset
    @State private var rows: [SAValue] = []
    @State private var summary: SAValue = .null
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var risk = ""
    @State private var nextCursor: String?
    @State private var page = 1
    @State private var offset = 0
    @State private var canLoadMore = false
    @State private var loadedAt: Date?
    @State private var generation = UUID()
    @State private var exportURL: URL?
    var body: some View {
        List {
            if dataset.kind == .access {
                Section {
                    Picker("Risk", selection: $risk) {
                        Text("All risks").tag(""); Text("Critical").tag("critical"); Text("High").tag("high"); Text("Medium").tag("medium")
                    }.onChange(of: risk) { _, _ in Task { await load(reset: true) } }
                }
            }
            if !summary["months"].array.isEmpty {
                Section("Company growth") {
                    Chart(Array(summary["months"].array.enumerated()), id: \.offset) { index, month in
                        BarMark(x: .value("Month", month.text), y: .value("Companies", summary["counts"].array.indices.contains(index) ? (summary["counts"].array[index].number ?? 0) : 0))
                            .foregroundStyle(Color.taliaAccent)
                    }.frame(height: 200)
                    Text("Current active accounts by signup month").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !summary.isNull { Section { SAFields(value: summary, depth: 0) } }
            if !rows.isEmpty {
                Section {
                    ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                        NavigationLink {
                            SARecordDetail(store: store, record: row, kind: dataset.kind)
                        } label: { SARecordRow(value: row, kind: dataset.kind) }
                        .listRowBackground(Color.taliaSecondaryBackground)
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red); Button("Try again") { Task { await load(reset: true) } } } }
            if loading { ProgressView("Loading \(dataset.title.lowercased())…") }
            if !loading && error == nil && rows.isEmpty && summary.isNull {
                ContentUnavailableView("No records", systemImage: "tray", description: Text("No results for the current filters."))
            }
            if canLoadMore && !loading { Button("Load more") { Task { await load(reset: false) } } }
            if dataset.kind == .tenant && !visibleRows.isEmpty {
                Section("Export") {
                    Button("Prepare CSV for these companies") { Task { await exportCompanies() } }
                    if let exportURL { ShareLink("Save or share CSV", item: exportURL) }
                }
            }
            if let loadedAt { Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        }.taliaSurface()
        .searchable(text: $query, prompt: searchPrompt)
        .onSubmit(of: .search) { appliedQuery = query; Task { await load(reset: true) } }
        .onChange(of: query) { _, value in if value.isEmpty && !appliedQuery.isEmpty { appliedQuery = ""; Task { await load(reset: true) } } }
        .refreshable { await load(reset: true) }
        .task { await load(reset: true) }
        .onDisappear {
            generation = UUID()
            if let exportURL { try? FileManager.default.removeItem(at: exportURL); self.exportURL = nil }
        }
    }
    private func exportCompanies() async {
        guard let api = store.api else { return }
        do {
            let snapshot = visibleRows, scope = store.sessionRevision
            _ = try await api.request("admin/exports/log", method: "POST", body: ["resource": .string("tenants"), "row_count": .number(Double(snapshot.count)), "filters": .object(["search": .string(query), "view": .string(dataset.title)])])
            guard scope == store.sessionRevision else { return }
            let keys = ["name", "primary_email", "status", "plan_tier", "billing_cycle", "seats_allowed", "trial_ends_at", "created_at"]
            func cell(_ value: String) -> String {
                let protected = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
                return "\"" + protected.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let csv = "\u{FEFF}" + ([keys.map { cell(saLabel($0)) }.joined(separator: ",")] + snapshot.map { row in keys.map { cell(row[$0].text) }.joined(separator: ",") }).joined(separator: "\r\n")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("talia-companies-\(UUID().uuidString).csv")
            try Data(csv.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }
            exportURL = url
        } catch { self.error = error.localizedDescription }
    }
    private var remoteSearch: Bool { [.developer, .access, .listing, .exchangeCase, .dealer].contains(dataset.kind) || dataset.path.contains("watch-validations") || dataset.path.contains("email-log") || dataset.path.contains("audit-logs") }
    private var searchPrompt: String {
        if dataset.path.contains("email-log") { return "Recipient email" }
        if dataset.path.contains("audit-logs") { return "Action (e.g. tenant.suspend)" }
        if dataset.path.contains("watch-validations") { return "Brand" }
        return remoteSearch ? "Search records" : "Search loaded records"
    }
    private var visibleRows: [SAValue] {
        if remoteSearch || query.isEmpty { return rows }
        return rows.filter { row in row.object.values.contains { $0.text.localizedCaseInsensitiveContains(query) } }
    }
    private func load(reset: Bool) async {
        guard let api = store.api else { return }
        if !reset && loading { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let session = store.sessionRevision
        if reset { page = 1; offset = 0; nextCursor = nil; rows = []; summary = .null; canLoadMore = false }
        var components = URLComponents(string: "https://app.taliaai.com/\(dataset.path)")!
        var params = components.queryItems ?? []
        if remoteSearch && !appliedQuery.isEmpty {
            let key = dataset.kind == .developer ? "q" : dataset.path.contains("watch-validations") ? "brand" : dataset.path.contains("email-log") ? "to_email" : dataset.path.contains("audit-logs") ? "action" : "search"
            params.append(.init(name: key, value: appliedQuery))
        }
        if !risk.isEmpty { params.append(.init(name: "risk", value: risk)) }
        switch dataset.pagination {
        case .offset: params += [.init(name: "limit", value: "50"), .init(name: "offset", value: String(offset))]
        case .page: params += [.init(name: "page", value: String(page)), .init(name: "page_size", value: "50")]
        case .cursor: if let nextCursor { params.append(.init(name: "cursor", value: nextCursor)) }
        case .beforeID: if let nextCursor { params.append(.init(name: "before_id", value: nextCursor)) }
        case .beforeDate: if let nextCursor { params.append(.init(name: "before", value: nextCursor)) }
        case .none: break
        }
        components.queryItems = params.isEmpty ? nil : params
        let path = String(components.path.dropFirst()) + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        do {
            let response = try await api.request(path)
            guard generation == current, session == store.sessionRevision, !Task.isCancelled else { return }
            let value = dataset.key.isEmpty ? response : response[dataset.key]
            if !dataset.key.isEmpty && value.isNull { throw SARequestError(status: 502, code: "CONTRACT", message: "The server response has changed. Refresh or update the app.") }
            if case .array(let incoming) = value {
                rows += incoming
                nextCursor = response["next_cursor"].isNull ? response["pagination"]["next_cursor"].text : response["next_cursor"].text
                if nextCursor?.isEmpty == true { nextCursor = nil }
                switch dataset.pagination {
                case .none: canLoadMore = false
                case .cursor, .beforeID, .beforeDate: canLoadMore = nextCursor != nil
                case .offset: canLoadMore = incoming.count == 50; offset += incoming.count
                case .page: canLoadMore = Double(rows.count) < (response["total"].number ?? 0); page += 1
                }
            } else { summary = value }
            loadedAt = Date()
        } catch { if generation == current && session == store.sessionRevision { self.error = error.localizedDescription } }
        if generation == current { loading = false }
    }
}

struct SARecordRow: View {
    let value: SAValue
    var kind: SADataset.Kind = .record
    private var status: String { value.first("severity", "risk_level", "status", "riskLevel", "confidence_band", "plan_tier") }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if kind == .alert || kind == .access {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(status == "critical" ? Color.red : Color.orange).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(value.recordTitle).font(.body.weight(.semibold)).lineLimit(2)
                let detail = value.first("reason", "primary_email", "to_email", "email", "reference_number", "path", "tenant_name", "description")
                if !detail.isEmpty && detail != value.recordTitle { Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                HStack {
                    if !status.isEmpty { Text(saLabel(status)).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.taliaTertiaryBackground, in: Capsule()) }
                    let date = value.first("created_at", "last_activity", "lastLoginAt")
                    if let parsed = ISO8601DateFormatter().date(from: date) { Text(parsed, style: .relative).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if kind == .alert && value["read_at"].isNull { Circle().fill(Color.taliaAccent).frame(width: 7, height: 7).accessibilityLabel("Unread") }
        }.padding(.vertical, 6)
    }
}

/// Native labelled fields and nested navigation, never HTML or a JSON text dump.
struct SAFields: View {
    let value: SAValue
    var depth = 0
    private var keys: [String] {
        value.object.keys.filter { !["accessToken", "refreshToken", "password", "password_hash", "mfa_secret", "invitation_token", "fingerprint", "expanded", "secret_id", "ecs_cluster", "ecs_service", "aws_region"].contains($0) && !value[$0].isNull }.sorted()
    }
    var body: some View {
        ForEach(keys, id: \.self) { key in
            let field = value[key]
            if !field.object.isEmpty || !field.array.isEmpty {
                NavigationLink {
                    List {
                        if !field.object.isEmpty { AnyView(SAFields(value: field, depth: depth + 1)) }
                        else {
                            ForEach(Array(field.array.enumerated()), id: \.offset) { _, row in
                                if !row.object.isEmpty { Section(row.recordTitle) { AnyView(SAFields(value: row, depth: depth + 1)) } }
                                else { Text(row.text).textSelection(.enabled) }
                            }
                        }
                    }.taliaSurface().navigationTitle(saLabel(key))
                } label: { LabeledContent(saLabel(key), value: field.array.isEmpty ? "Details" : String(field.array.count)) }
            } else if !field.text.isEmpty {
                LabeledContent {
                    Text(formatted(field, key: key)).multilineTextAlignment(.trailing).textSelection(.enabled)
                } label: { Text(saLabel(key)) }
            }
        }
    }
    private func formatted(_ field: SAValue, key: String) -> String {
        if key.hasSuffix("_cents") || key.hasSuffix("_pence") || key == "amount_minor" {
            return ((field.number ?? 0) / 100).formatted(.currency(code: value["currency"].text.isEmpty ? "GBP" : value["currency"].text.uppercased()))
        }
        if ["mrr", "arr"].contains(key), let number = field.number { return number.formatted(.currency(code: "GBP")) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: field.text) ?? ISO8601DateFormatter().date(from: field.text) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return field.text
    }
}

struct SAOverviewView: View {
    @ObservedObject var store: SuperAdminPortalStore
    @State private var metrics: SAValue = .null
    @State private var alertCount: Int?
    @State private var error: String?
    @State private var loading = true
    private let cards: [(String, String, String)] = [("active_tenants", "Active companies", "building.2"), ("trial_tenants", "On trial", "clock"), ("total_users", "People", "person.2"), ("new_tenants_this_month", "New this month", "chart.line.uptrend.xyaxis")]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("TALIA / ADMIN").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(.secondary)
                    Text("Your platform,\nat a glance.").font(.system(size: 32, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 12)
                if loading { ProgressView("Loading platform activity…") }
                if let error { Text(error).foregroundStyle(.red) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(cards, id: \.0) { key, title, icon in
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
                            Text(metrics[key].isNull ? "—" : metrics[key].text).font(.system(size: 32, weight: .semibold, design: .rounded))
                            Text(title).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).taliaCard()
                    }
                }
                Button { store.selectedTab = 1 } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bell.badge").font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Security alerts").font(.headline)
                            Text(alertCount.map { "\($0) unread incidents" } ?? "Review suspicious activity").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right")
                    }.taliaCard()
                }.buttonStyle(.plain)
                NavigationLink { SASectionView(store: store, section: .accessSecurity) } label: {
                    Label("Investigate access activity", systemImage: "shield.lefthalf.filled").frame(maxWidth: .infinity, alignment: .leading).taliaCard()
                }.buttonStyle(.plain)
                if !metrics.isNull { VStack(alignment: .leading) { Text("Platform totals").font(.headline); SAFields(value: metrics) }.taliaCard() }
            }.padding(20)
        }.background(Color.taliaBackground).refreshable { await load() }.task { await load() }
    }
    private func load() async {
        guard let api = store.api else { return }
        loading = true; error = nil; let scope = store.sessionRevision
        do {
            let result = try await api.request("admin/metrics")
            guard scope == store.sessionRevision else { return }; metrics = result["metrics"]
            if let status = try? await api.request("admin/mobile/status"), scope == store.sessionRevision { alertCount = status["unread"].number.map(Int.init) }
        } catch { if scope == store.sessionRevision { self.error = error.localizedDescription } }
        if scope == store.sessionRevision { loading = false }
    }
}
