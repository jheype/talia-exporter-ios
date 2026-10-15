import Foundation

extension AppModel {
    func openWorkspaceURL(_ url: URL) {
        guard url.scheme == "talia-exporter" else { return }
        guard let user, route != .loading else { pendingWorkspaceURL = url; return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let account = query.first(where: { $0.name == "account" })?.value,
           UUID(uuidString: account) != user.id { return }
        let itemID = query.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
        switch url.host {
        case "tasks":
            workspace.section = .board
            var filters = WorkFilters()
            filters.search = query.first { $0.name == "search" }?.value ?? ""
            filters.status = WorkStatus(rawValue: query.first { $0.name == "status" }?.value ?? "") ?? .inProgress
            filters.due = query.first { $0.name == "due" }?.value ?? ""
            workspace.filters = filters
            selectedTab = .tasks
            workspace.requestedTaskID = itemID
            route = .main
        case "notes":
            workspace.section = .notes
            workspace.requestedNoteID = itemID
            selectedTab = .tasks
            route = .main
        case "activity": selectedTab = .activity
        case "groups": selectedTab = .groups
        case "settings": selectedTab = .settings
        default: selectedTab = .home
        }
    }

    func resumeWorkspaceURL() {
        guard user != nil, let url = pendingWorkspaceURL else { return }
        pendingWorkspaceURL = nil
        openWorkspaceURL(url)
    }
}
