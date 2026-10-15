import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension AppModel {
    @discardableResult
    func saveGroupRouting(
        groupID: String,
        function: GroupFunction,
        botFeedbackEnabled: Bool,
        botRemindersEnabled: Bool,
        botDestinationID: String?,
        expectedRevision: Int64
    ) async -> Bool {
        guard let user,
              route == .main,
              groups.contains(where: { $0.id == groupID }),
              expectedRevision >= 1,
              !routingSavingGroupIDs.contains(groupID) else { return false }
        let ownerUserID = user.id
        let accountGeneration = accountScopeGeneration
        let feedback = (function == .tasks || function == .logs) ? botFeedbackEnabled : false
        let reminders = function == .tasks ? botRemindersEnabled : false
        let destination = botDestinationID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        routingSavingGroupIDs.insert(groupID)
        defer {
            if accountGeneration == accountScopeGeneration,
               self.user?.id == ownerUserID {
                routingSavingGroupIDs.remove(groupID)
            }
        }

        do {
            let setting = try await api.setGroupRouting(
                GroupRoutingRequest(
                    groupJID: groupID,
                    function: function,
                    botFeedbackEnabled: feedback,
                    botRemindersEnabled: reminders,
                    botDestinationID: destination?.isEmpty == false ? destination : nil,
                    expectedRevision: expectedRevision
                )
            )
            guard accountGeneration == accountScopeGeneration,
                  self.user?.id == ownerUserID,
                  route == .main,
                  let currentIndex = groups.firstIndex(where: { $0.id == setting.groupJID }) else {
                return false
            }
            groups[currentIndex].function = setting.function
            groups[currentIndex].functionRevision = setting.revision
            groups[currentIndex].botFeedbackEnabled = setting.botFeedbackEnabled
            groups[currentIndex].botRemindersEnabled = setting.botRemindersEnabled
            groups[currentIndex].botDestinationID = setting.botDestinationID
            await persistDashboard()
            await refreshWidgetSnapshot(force: true, showErrors: false)
            return true
        } catch {
            guard accountGeneration == accountScopeGeneration,
                  self.user?.id == ownerUserID,
                  route == .main
            else { return false }
            if let apiError = error as? APIError, apiError.statusCode == 409 {
                await refreshGroups(showErrors: false)
            }
            guard accountGeneration == accountScopeGeneration,
                  self.user?.id == ownerUserID,
                  route == .main
            else { return false }
            await handle(error, title: "Group function not saved")
            return false
        }
    }

    func saveWidgetPreferences(_ preferences: WidgetPreferences) async {
        var validated = preferences.normalisedForStorage()
        let taskGroupIDs = Set(groups.lazy.filter { $0.effectiveFunction == .tasks }.map(\.id))
        let messageGroupIDs = Set(groups.lazy.filter {
            $0.isSelected && ($0.effectiveFunction == .tasks
                || (validated.includeLogs && $0.effectiveFunction == .logs))
        }.map(\.id))
        if !validated.taskGroupJID.isEmpty, !taskGroupIDs.contains(validated.taskGroupJID) {
            validated.taskGroupJID = ""
        }
        if !validated.messageGroupJID.isEmpty, !messageGroupIDs.contains(validated.messageGroupJID) {
            validated.messageGroupJID = ""
        }
        widgetPreferences = validated
        WidgetSharedStore.savePreferences(validated)
        // Hide content immediately, even when the following network refresh fails.
        if let owner = user?.id {
            let existing = widgetSnapshot ?? WidgetSharedStore.loadEnvelope().flatMap {
                $0.ownerUserID == owner ? $0.snapshot : nil
            }
            if let existing {
                do {
                    try WidgetSharedStore.save(snapshot: existing, ownerUserID: owner, preferences: validated)
                } catch {
                    // Removing the snapshot is safer than retaining newly hidden text.
                    WidgetSharedStore.clearSnapshot()
                }
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
                #endif
            }
        }
        await refreshWidgetSnapshot(force: true, showErrors: true)
    }

    func refreshWidgetSnapshot(force: Bool = false, showErrors: Bool = false) async {
        guard let user, route == .main else { return }
        if !force,
           let widgetLastRefreshedAt,
           Date().timeIntervalSince(widgetLastRefreshedAt) < 60 {
            return
        }
        widgetRefreshGeneration &+= 1
        let generation = widgetRefreshGeneration
        let ownerUserID = user.id
        let preferences = widgetPreferences
        do {
            let snapshot = try await api.widgetSnapshot(preferences: preferences)
            guard generation == widgetRefreshGeneration,
                  self.user?.id == ownerUserID,
                  route == .main,
                  widgetPreferences == preferences
            else { return }
            widgetSnapshot = snapshot
            try WidgetSharedStore.save(
                snapshot: snapshot,
                ownerUserID: ownerUserID,
                preferences: preferences
            )
            widgetLastRefreshedAt = Date()
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            guard generation == widgetRefreshGeneration,
                  self.user?.id == ownerUserID,
                  route == .main,
                  widgetPreferences == preferences
            else { return }
            if showErrors {
                await handle(error, title: "Widgets not refreshed")
            }
        }
    }
}
