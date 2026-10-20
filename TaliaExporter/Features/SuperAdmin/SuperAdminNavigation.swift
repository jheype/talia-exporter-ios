import Foundation

/// All admin screens use native controls and these server-authorised API resources.
enum SuperAdminSection: String, CaseIterable, Identifiable {
    case overview, tenants, billing, developers, pricing, exchange, analytics
    case aiUsage = "ai-usage", watchSignals = "watch-validations", emailLog = "email-log"
    case audit, accessSecurity = "access-security", security
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .tenants: "Tenants"
        case .billing: "Billing"
        case .developers: "Developers"
        case .pricing: "Pricing"
        case .exchange: "Exchange"
        case .analytics: "Analytics"
        case .aiUsage: "AI Usage"
        case .watchSignals: "Watch Signals"
        case .emailLog: "Email Log"
        case .audit: "Audit Log"
        case .accessSecurity: "Access Security"
        case .security: "Security"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .tenants: "building.2"
        case .billing: "creditcard"
        case .developers: "curlybraces"
        case .pricing: "sterlingsign.circle"
        case .exchange: "arrow.left.arrow.right"
        case .analytics: "chart.xyaxis.line"
        case .aiUsage: "sparkles"
        case .watchSignals: "watch.analog"
        case .emailLog: "envelope"
        case .audit: "list.bullet.rectangle"
        case .accessSecurity: "shield.lefthalf.filled"
        case .security: "lock.shield"
        }
    }
    var datasets: [SADataset] {
        switch self {
        case .overview: [.init("Platform", "admin/metrics", "metrics"), .init("Trials ending", "admin/billing/trials-ending?days=14", "trials"), .init("Churn signals", "admin/churn-signals", "churnSignals")]
        case .tenants: [.init("Companies", "admin/tenants?scope=all", "tenants", kind: .tenant), .init("Signup links", "admin/invitations/signup-links", "invitations", kind: .signupLink)]
        case .billing: [.init("Revenue", "admin/billing/revenue"), .init("Trials ending", "admin/billing/trials-ending?days=14", "trials", kind: .tenant), .init("Subscriptions", "admin/tenants", "tenants", kind: .tenant)]
        case .developers: [.init("Accounts", "admin/partner-api/clients", "data", kind: .developer, pagination: .cursor)]
        case .pricing: [.init("Plans", "admin/pricing", "pricing", kind: .plan), .init("Changes", "admin/plans/jobs?limit=50", "jobs"), .init("Stripe environment", "admin/plans/env")]
        case .exchange: [.init("Overview", "admin/exchange/overview"), .init("Listings", "admin/exchange/listings", "data", kind: .listing, pagination: .page), .init("Cases", "admin/exchange/cases", "data", kind: .exchangeCase, pagination: .page), .init("Dealers", "admin/exchange/dealers", "data", kind: .dealer, pagination: .page)]
        case .analytics: [.init("Metrics", "admin/metrics", "metrics"), .init("Growth", "admin/metrics/growth"), .init("Churn", "admin/churn-signals", "churnSignals")]
        case .aiUsage: [.init("Tenant usage", "admin/token-usage", "tenants", kind: .aiUsage), .init("Models", "admin/llm-config")]
        case .watchSignals: [.init("Signals", "admin/watch-validations", "items", pagination: .offset), .init("Validation history", "admin/watch-validations/audit", "items", pagination: .offset)]
        case .emailLog: [.init("Messages", "admin/email-log", "entries", pagination: .offset)]
        case .audit: [.init("Actions", "admin/audit-logs", "logs", pagination: .offset)]
        case .accessSecurity: [.init("Summary", "admin/access-security/summary"), .init("Requests", "admin/access-security/logs", "items", kind: .access, pagination: .beforeID), .init("Blocked accounts", "admin/access-security/blocked-accounts", "items", kind: .blocked)]
        case .security: []
        }
    }
}
struct SADataset: Identifiable, Hashable {
    enum Kind: Hashable { case record, signupLink, tenant, developer, plan, listing, exchangeCase, dealer, aiUsage, access, blocked, alert }
    enum Pagination: Hashable { case none, offset, page, cursor, beforeID, beforeDate }
    let title: String, path: String, key: String
    var kind: Kind, pagination: Pagination
    var id: String { path }
    init(_ title: String, _ path: String, _ key: String = "", kind: Kind = .record, pagination: Pagination = .none) {
        self.title = title; self.path = path; self.key = key; self.kind = kind; self.pagination = pagination
    }
    static let alerts = SADataset("Alerts", "admin/mobile/alerts", "items", kind: .alert, pagination: .beforeDate)
}

indirect enum SAValue: Codable, Equatable, Sendable {
    case object([String: SAValue]), array([SAValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([SAValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: SAValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> SAValue { object[key] ?? .null }
    var object: [String: SAValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [SAValue] { if case .array(let v) = self { return v }; return [] }
    var text: String {
        switch self {
        case .string(let v): v
        case .number(let v): v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
        case .bool(let v): v ? "Yes" : "No"
        default: ""
        }
    }
    var flag: Bool { self == .bool(true) }
    var number: Double? { if case .number(let v) = self { return v }; return Double(text) }
    var isNull: Bool { self == .null }
    func first(_ keys: String...) -> String { keys.map { self[$0].text }.first { !$0.isEmpty } ?? "" }
    var recordTitle: String {
        let value = first("title", "name", "tenant_name", "display_name", "company_name", "email", "account_email", "subject", "plan_tier", "brand", "action", "path", "date", "month")
        return value.isEmpty ? "Details" : value
    }
    var recordID: String { first("id", "tenant_id", "user_id", "catalog_id", "plan_tier") }
}

func saLabel(_ key: String) -> String {
    key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "_", with: " ").capitalized
}
