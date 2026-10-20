import SwiftUI

struct SAField: Identifiable {
    enum Kind { case text, password, integer, decimal, integerList, toggle, choice([String]) }
    let key: String, label: String
    var kind: Kind = .text
    var initial = ""
    var required = true
    var id: String { key }
    init(_ key: String, _ label: String, kind: Kind = .text, initial: String = "", required: Bool = true) {
        self.key = key; self.label = label; self.kind = kind; self.initial = initial; self.required = required
    }
    static let reason = SAField("reason", "Reason for this change")
    static let sellerNotice = SAField("seller_notice", "Message shown to the seller")
    static let plan = SAField("plan_tier", "Plan", kind: .choice(["dealer", "pro", "professional", "price_intel"]), initial: "dealer")
}
struct SAAction: Identifiable {
    let id = UUID()
    let title: String, path: String
    var method = "POST"
    var body: [String: SAValue] = [:]
    var fields: [SAField] = []
    var warning = "Review this change before confirming. It will be recorded in the admin audit history."
    var confirmation: String?
    var nestedChanges = false
    init(_ title: String, _ path: String, method: String = "POST", body: [String: SAValue] = [:], fields: [SAField] = [], warning: String = "Review this change before confirming. It will be recorded in the admin audit history.", confirmation: String? = nil, nestedChanges: Bool = false) {
        self.title = title; self.path = path; self.method = method; self.body = body; self.fields = fields
        self.warning = warning; self.confirmation = confirmation; self.nestedChanges = nestedChanges
    }
    static var createTenant: SAAction {
        .init("Create company", "admin/tenants", fields: [
            .init("name", "Company name"), .init("admin_email", "Admin email"), .init("admin_password", "Initial password", kind: .password),
            .init("admin_first_name", "First name"), .init("admin_last_name", "Last name"), .plan,
            .init("is_demo", "Demo company", kind: .toggle), .init("trial_duration_days", "Trial days", kind: .integer, initial: "14"), .init("status", "Initial status", kind: .choice(["active", "trialing", "comped"]), initial: "trialing"), .init("billing_cycle", "Billing cycle", kind: .choice(["monthly", "annual"]), initial: "monthly")])
    }
    static var signupLink: SAAction { .init("Generate signup link", "admin/invitations/generate-signup-link", warning: "Creates a reusable signup link. Share it only with the intended recipients.") }
}

struct SAActionView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let action: SAAction
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var confirmation = ""
    @State private var confirming = false
    @State private var busy = false
    @State private var uncertain = false
    @State private var error: String?
    @State private var result: SAValue?
    init(store: SuperAdminPortalStore, action: SAAction, completed: @escaping () -> Void) {
        self.store = store; self.action = action; self.completed = completed
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: action.fields.map { ($0.key, $0.initial) }))
    }
    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    Section { Label("Request completed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.taliaLive) }
                    Section { SAFields(value: result) }
                    Button("Done") { completed(); dismiss() }
                } else {
                    Section { Text(action.warning).foregroundStyle(.secondary) }
                    Section {
                        ForEach(action.fields) { field in fieldView(field) }
                    }
                    if let expected = action.confirmation {
                        Section("Type \(expected) to confirm") { TextField(expected, text: $confirmation).textInputAutocapitalization(.never).autocorrectionDisabled() }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                    if uncertain { Text("The connection ended before the result was confirmed. Close this form and refresh the record before making another change.").font(.footnote) }
                    Button(action.title) { confirming = true }.disabled(!valid || busy || uncertain)
                    if busy { ProgressView("Saving…") }
                }
            }.taliaSurface().navigationTitle(action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Close") { if result != nil { completed() }; dismiss() }.disabled(busy) } }
            .confirmationDialog(action.title + "?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Confirm change") { Task { await submit() } }
            } message: { Text(action.warning) }
            .interactiveDismissDisabled(busy)
        }.tint(.taliaAccent)
    }
    @ViewBuilder private func fieldView(_ field: SAField) -> some View {
        let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
        switch field.kind {
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { values[field.key] == "true" }, set: { values[field.key] = $0 ? "true" : "false" }))
        case .choice(let options):
            Picker(field.label, selection: binding) { ForEach(options, id: \.self) { Text(saLabel($0)).tag($0) } }
        case .password: SecureField(field.label, text: binding).textContentType(.password)
        case .integer: TextField(field.label, text: binding).keyboardType(.numberPad)
        case .decimal: TextField(field.label, text: binding).keyboardType(.decimalPad)
        case .integerList: TextField(field.label + " (comma separated)", text: binding).keyboardType(.numbersAndPunctuation)
        case .text: TextField(field.label, text: binding, axis: .vertical).textInputAutocapitalization(.sentences).autocorrectionDisabled()
        }
    }
    private var valid: Bool {
        if let expected = action.confirmation, confirmation != expected { return false }
        return action.fields.allSatisfy { field in
            let value = values[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.kind {
            case .toggle: return true
            case .integer: return (!field.required && value.isEmpty) || Int(value) != nil
            case .decimal: return (!field.required && value.isEmpty) || Double(value.replacingOccurrences(of: ",", with: ".")) != nil
            case .integerList: return (!field.required && value.isEmpty) || (!value.isEmpty && value.split(separator: ",").allSatisfy { Int($0.trimmingCharacters(in: .whitespaces)) != nil })
            default: return !field.required || !value.isEmpty
            }
        }
    }
    private func submit() async {
        guard !busy, valid, let api = store.api else { return }; busy = true; error = nil
        let scope = store.sessionRevision
        var body = action.body, changes: [String: SAValue] = [:]
        for field in action.fields {
            let text = values[field.key, default: ""]
            if !field.required && text.isEmpty { continue }
            let value: SAValue
            switch field.kind {
            case .integer: value = .number(Double(text) ?? 0)
            case .decimal: value = .number(Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0)
            case .integerList: value = .array(text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { .number($0) })
            case .toggle: value = .bool(text == "true")
            default: value = .string(text)
            }
            if action.nestedChanges && !["reason", "seller_notice", "evidence", "seller_instruction"].contains(field.key) { changes[field.key] = value }
            else { body[field.key] = value }
        }
        if action.nestedChanges { body["changes"] = .object(changes) }
        do {
            let response = try await api.request(action.path, method: action.method, body: body, requestID: action.id.uuidString)
            guard scope == store.sessionRevision else { return }
            result = response.isNull ? .object(["message": .string("Saved")]) : response
        } catch {
            guard scope == store.sessionRevision else { return }
            self.error = error.localizedDescription
            uncertain = (error as? SARequestError).map { $0.status >= 500 || $0.status == 0 } ?? true
        }
        busy = false
    }
}

struct SARecordDetail: View {
    @ObservedObject var store: SuperAdminPortalStore
    let record: SAValue
    let kind: SADataset.Kind
    @State private var detail: SAValue = .null
    @State private var error: String?
    @State private var loading = false
    @State private var action: SAAction?
    var body: some View {
        List {
            if loading { ProgressView("Loading details…") }
            if let error { Text(error).foregroundStyle(.red); Button("Refresh") { Task { await load() } } }
            if !loading && error == nil {
                Section { SAFields(value: mainRecord) }
                if !actions.isEmpty { Section("Actions") { ForEach(actions) { item in Button(item.title) { action = item } } } }
                if kind == .tenant {
                    Section("People") {
                        ForEach(Array(detail["users"].array.enumerated()), id: \.offset) { _, user in
                            NavigationLink(user["email"].text) { SAUserView(store: store, user: user, tenantID: record.recordID) }
                        }
                    }
                    Section("Usage") {
                        NavigationLink("Activity and feature usage") { SADatasetView(store: store, dataset: .init("Usage", "admin/tenants/\(record.recordID)/usage?days=30")) }
                        NavigationLink("AI status") { SADatasetView(store: store, dataset: .init("AI status", "admin/tenants/\(record.recordID)/ai-status")) }
                    }
                }
                if kind == .developer {
                    Section("People and API keys") {
                        ForEach(Array(detail["accounts"].array.enumerated()), id: \.offset) { _, account in
                            Button((account["disabled_at"].isNull ? "Suspend " : "Restore ") + account["email"].text) {
                                action = .init("Change developer login", "admin/partner-api/clients/\(record.recordID)/accounts/\(account.recordID)/access", body: ["enabled": .bool(!account["disabled_at"].isNull)], fields: [.reason])
                            }
                        }
                        ForEach(Array(detail["keys"].array.enumerated()), id: \.offset) { _, key in
                            if key["revoked_at"].isNull {
                                Button("Revoke key: \(key["label"].text)", role: .destructive) {
                                    action = .init("Revoke API key", "admin/partner-api/clients/\(record.recordID)/keys/\(key.recordID)", method: "DELETE", fields: [.reason])
                                }
                            }
                        }
                        NavigationLink("Usage in the last 30 days") { SADatasetView(store: store, dataset: .init("Usage", "admin/partner-api/clients/\(record.recordID)/usage?days=30", "data")) }
                    }
                }
                if kind == .listing {
                    Section("Photos") {
                        ForEach(Array(detail["photos"].array.enumerated()), id: \.offset) { _, photo in
                            if let url = URL(string: photo["url"].text), url.scheme == "https" {
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                                    .frame(maxWidth: .infinity).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 14))
                                Text("Photo index: \(photo["index"].text)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Active holds") {
                        ForEach(Array(detail["holds"].array.enumerated()), id: \.offset) { _, hold in
                            if hold["state"].text != "released" {
                                Button("Release hold: \(hold.first("reason", "kind"))") {
                                    action = .init("Release listing hold", "admin/exchange/listings/\(record.recordID)/moderation", body: ["action": .string("restore"), "revision": mainRecord["revision"], "case_id": hold["case_id"]], fields: [.reason, .sellerNotice])
                                }
                            }
                        }
                    }
                }
                if detail != mainRecord && !detail.isNull {
                    Section("More details") { SAFields(value: remainingDetails) }
                }
            }
        }.taliaSurface().navigationTitle(record.recordTitle).navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .sheet(item: $action, onDismiss: { Task { await load() } }) { item in SAActionView(store: store, action: item) {} }
    }
    private var mainRecord: SAValue {
        guard !detail.isNull else { return record }
        if kind == .tenant { return detail["tenant"] }
        if kind == .listing { return detail["listing"] }
        return detail
    }
    private var remainingDetails: SAValue { .object(detail.object.filter { !["tenant", "listing", "users"].contains($0.key) }) }
    private func load() async {
        guard let api = store.api else { return }; loading = true; error = nil
        let scope = store.sessionRevision
        var path: String?
        switch kind {
        case .tenant: path = "admin/tenants/\(record.recordID)/detail"
        case .developer: path = "admin/partner-api/clients/\(record.recordID)"
        case .plan: path = "admin/plans/\(record["plan_tier"].text)/preview"
        case .listing: path = "admin/exchange/listings/\(record.recordID)"
        case .aiUsage: path = "admin/token-usage/\(record["tenant_id"].text)"
        case .alert: path = "admin/mobile/alerts/\(record.recordID)"
        default: break
        }
        do {
            if let path {
                let value = try await api.request(path)
                guard scope == store.sessionRevision, !Task.isCancelled else { return }
                detail = kind == .developer ? value["data"] : value
                if kind == .alert { _ = try? await api.request("admin/mobile/alerts/\(record.recordID)/read", method: "POST", body: [:]) }
            } else { detail = record }
        } catch { if scope == store.sessionRevision { self.error = error.localizedDescription } }
        if scope == store.sessionRevision { loading = false }
    }
    private var actions: [SAAction] {
        let id = record.recordID, row = mainRecord
        switch kind {
        case .signupLink:
            return row["status"].text == "revoked" ? [] : [.init("Revoke signup link", "admin/invitations/\(id)", method: "DELETE", warning: "Stops further signups using this link.")]
        case .tenant:
            let path = "admin/tenants/\(id)"
            let archived = ["pending_deletion", "deleted", "archived"].contains(row["status"].text)
            var items: [SAAction] = [
                .init(archived ? "Restore company" : "Activate company", path + "/status", body: ["action": .string(archived ? "restore" : "activate")]),
                .init("Change plan", path + "/plan", fields: [.plan], warning: "Changes this company's subscription plan. Stripe billing may be updated."),
                .init("Extend trial", path + "/trial", body: ["action": .string("extend")], fields: [.init("days", "Additional days (1–90)", kind: .integer, initial: "7")]),
                .init("End trial now", path + "/trial", body: ["action": .string("end_now")]),
                .init("Edit company settings", path, method: "PATCH", fields: [.init("is_demo", "Demo company", kind: .toggle, initial: row["is_demo"].flag ? "true" : "false"), .init("seats_allowed", "Seats allowed", kind: .integer, initial: row["seats_allowed"].text), .init("price_override_cents", "Price override (pence)", kind: .integer, required: false)]),
                .init("Set AI access", path + "/ai-enabled", method: "PATCH", fields: [.init("enabled", "AI enabled", kind: .toggle)]),
                .init("Retry failed payment", "admin/billing/retry-payment", body: ["tenantId": .string(id)], warning: "Asks Stripe to retry this company's failed payment."),
                .init("Cancel subscription", "admin/billing/cancel-subscription", body: ["tenantId": .string(id)], fields: [.init("immediately", "Cancel immediately", kind: .toggle)], warning: "Cancels the company's subscription. Review its current billing status first.", confirmation: row["name"].text)
            ]
            if !archived {
                items += [.init("Suspend company", path + "/status", body: ["action": .string("suspend")], warning: "Stops this company's access to Talia."), .init("Archive company", path + "/status", body: ["action": .string("archive")], warning: "Archives the company and stops access. Records are retained.", confirmation: row["name"].text)]
            }
            return items
        case .developer:
            let path = "admin/partner-api/clients/\(id)"
            return [
                .init(row["enabled"].flag ? "Suspend API access" : "Restore API access", path + "/access", body: ["enabled": .bool(!row["enabled"].flag)], fields: [.reason]),
                .init("Grant trial", path + "/trial", fields: [.init("queries", "Queries (1–10000)", kind: .integer, initial: "100"), .init("days", "Days (1–90)", kind: .integer, initial: "14"), .reason]),
                .init("End trial", path + "/trial/end", fields: [.reason]),
                .init("Change subscription renewal", path + "/subscription", fields: [.init("cancel_at_period_end", "Cancel at period end", kind: .toggle), .reason])
            ]
        case .plan:
            let tier = record["plan_tier"].text
            return [.init("Change plan price", "admin/plans/\(tier)/reprice", body: ["currency": .string("gbp")], fields: [.init("amount_pence", "New monthly price (pence)", kind: .integer, initial: record["monthly_price_cents"].text), .init("seats_included", "Included seats", kind: .integer, initial: record["seats_included"].text)], warning: "Creates a Stripe price and publishes the new plan. Review the preview above and the Stripe environment before continuing.", confirmation: tier),
                .init("Migrate subscriptions", "admin/plans/\(tier)/migrate-subscriptions", body: ["proration_behavior": .string("none")], fields: [.init("old_price_id", "Old Stripe price ID"), .init("new_price_id", "New Stripe price ID")], warning: "Moves existing subscriptions to the new price with no proration.", confirmation: tier)]
        case .access, .blocked, .alert:
            let event = kind == .alert ? detail["access_event"] : row
            let userID = event["user_id"].text
            guard !userID.isEmpty, !event["account_is_super_admin"].flag else { return [] }
            let unblock = kind == .blocked || event["account_is_blocked"].flag
            var body: [String: SAValue] = [:]
            if !unblock, let logID = event["id"].number { body["source_log_id"] = .number(logID) }
            return [.init(unblock ? "Unblock account" : "Block account", "admin/access-security/accounts/\(userID)/\(unblock ? "unblock" : "block")", body: body, fields: [.reason], warning: unblock ? "Restores access to this account." : "Revokes this account's sessions and blocks future sign-ins. This is reversible.")]
        case .listing:
            let revision = row["revision"]
            return ["hide", "remove", "request_correction"].map { mode in
                SAAction(saLabel(mode), "admin/exchange/listings/\(id)/moderation", body: ["action": .string(mode), "revision": revision], fields: [.reason, .sellerNotice])
            } + [.init("Edit listing", "admin/exchange/listings/\(id)", method: "PATCH", body: ["revision": revision], fields: [.init("description", "Description", initial: row["description"].text), .init("location", "Location", initial: row["location"].text), .reason, .sellerNotice], nestedChanges: true),
                .init("Edit watch specifications", "admin/exchange/listings/\(id)", method: "PATCH", body: ["revision": revision], fields: ["brand", "model", "reference", "year", "dial", "bezel", "strap", "condition", "set_details"].map { SAField($0, saLabel($0), kind: $0 == "year" ? .integer : .text, initial: row[$0].text, required: false) } + [.init("evidence", "Evidence for specification changes"), .init("seller_instruction", "Instructions for the seller"), .reason, .sellerNotice], nestedChanges: true),
                .init("Change listing price", "admin/exchange/listings/\(id)", method: "PATCH", body: ["revision": revision], fields: [.init("asking_price", "Asking price", kind: .decimal, initial: row["asking_price"].text), .init("currency", "Currency", kind: .choice(["GBP", "USD", "EUR", "HKD"]), initial: row["currency"].text), .init("seller_instruction", "Instructions for the seller"), .reason, .sellerNotice], nestedChanges: true),
                .init("Reorder listing photos", "admin/exchange/listings/\(id)", method: "PATCH", body: ["revision": revision], fields: [.init("photo_indices", "Photo indices", kind: .integerList), .reason, .sellerNotice], warning: "Enter the photo indices in their new order, as shown in the photo details.", nestedChanges: true)]
        case .exchangeCase:
            return [.init("Update moderation case", "admin/exchange/cases/\(id)", method: "PATCH", body: ["revision": row["revision"]], fields: [.init("status", "Status", kind: .choice(["new", "reviewing", "awaiting_seller", "resolved"]), initial: row["status"].text), .reason])]
        case .dealer:
            return [.init("Change trading restriction", "admin/exchange/dealers/\(id)/restriction", body: ["revision": row["revision"].isNull ? .number(0) : row["revision"]], fields: [.init("restricted", "Restrict trading", kind: .toggle, initial: row["restricted"].flag ? "true" : "false"), .reason, .sellerNotice])]
        default: return []
        }
    }
}

private struct SAUserView: View {
    @ObservedObject var store: SuperAdminPortalStore
    let user: SAValue, tenantID: String
    @State private var action: SAAction?
    var body: some View {
        List {
            SAFields(value: user)
            Section("Account actions") {
                Button("Generate password reset link") { action = .init("Generate reset link", "admin/users/\(user.recordID)/reset-password", body: ["send_email": .bool(false), "return_link": .bool(true)]) }
                Button("Send password reset email") { action = .init("Send password reset", "admin/users/\(user.recordID)/reset-password", body: ["send_email": .bool(true), "return_link": .bool(false)], warning: "Sends a password reset email to \(user["email"].text).") }
                Button("Resend invitation") { action = .init("Resend invitation", "admin/users/\(user.recordID)/resend-invite", body: ["send_email": .bool(true)], warning: "Sends a new invitation email to \(user["email"].text).") }
                if !user["isSuperAdmin"].flag {
                    Button("Remove user", role: .destructive) { action = .init("Remove user", "admin/tenants/\(tenantID)/users/\(user.recordID)", method: "DELETE", warning: "Removes this user profile and revokes its sessions.", confirmation: user["email"].text) }
                }
            }
        }.taliaSurface().navigationTitle(user["email"].text).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $action) { item in SAActionView(store: store, action: item) {} }
    }
}
