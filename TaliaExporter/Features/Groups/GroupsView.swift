import SwiftUI

struct GroupsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""

    private var filteredGroups: [ExportGroup] {
        guard !searchText.isEmpty else { return appModel.groups }
        return appModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filteredGroups) { group in
                        Button {
                            appModel.toggleGroup(group)
                        } label: {
                            GroupSelectionRow(group: group)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(group.name), \(group.isSelected ? "selected" : "not selected")")
                        .accessibilityHint("Double tap to toggle capture for this group")
                    }
                } header: {
                    Text("Available groups")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Groups")
            .searchable(text: $searchText, prompt: "Search groups")
            .refreshable {
                await appModel.refreshGroups()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Select all", systemImage: "checkmark.circle") {
                            appModel.selectAllGroups()
                        }

                        Button("Clear selection", systemImage: "circle") {
                            appModel.clearGroupSelection()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                selectionSummary
            }
        }
    }

    private var selectionSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.taliaBlue)

            Text("\(appModel.selectedGroupsDescription) selected")
                .font(.subheadline.weight(.semibold))

            Spacer()

            LivePill(
                title: appModel.compactCaptureStatus,
                colour: appModel.captureStatusColour
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct GroupSelectionRow: View {
    let group: ExportGroup

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatar(initials: group.initials)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Text(group.category)
                    Text("•")
                    Text(group.lastActivity)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(group.isSelected ? Color.taliaBlue : Color.secondary.opacity(0.45))
                .contentTransition(.symbolEffect(.replace))
        }
        .contentShape(Rectangle())
        .padding(.vertical, 5)
    }
}

#Preview {
    GroupsView()
        .environmentObject(AppModel.preview())
}
