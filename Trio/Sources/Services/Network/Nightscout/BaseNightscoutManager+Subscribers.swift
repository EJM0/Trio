import Combine
import CoreData
import Foundation

extension BaseNightscoutManager {
    /// Call once from init. Hooks up:
    /// 1) external upload requests (NotificationCenter)
    /// 2) Core Data change triggers → kicks per lane
    /// 3) Glucose storage updates → kick glucose lane
    func wireSubscribers() {
        wireExternalUploadRequests()
        wireCoreDataSubscribers()
        wireGlucoseStorageSubscriber()
    }

    /// Listens for `.nightscoutUploadRequested`, converts userInfo lanes to enums,
    /// and kicks those lanes. Posts `.nightscoutUploadDidFinish` after enqueuing.
    func wireExternalUploadRequests() {
        Foundation.NotificationCenter.default.publisher(for: .nightscoutUploadRequested)
            .sink { [weak self] note in
                guard let self else { return }
                let lanes = (note.userInfo?[NightscoutNotificationKey.lanes] as? [String])?
                    .compactMap(NightscoutLane.init(rawValue:)) ?? []

                for lane in lanes { self.kick(lane) }

                var info: [AnyHashable: Any] = [NightscoutNotificationKey.lanes: lanes.map(\.rawValue)]
                if let src = note.userInfo?[NightscoutNotificationKey.source] { info[NightscoutNotificationKey.source] = src }
                Foundation.NotificationCenter.default.post(name: .nightscoutUploadDidFinish, object: nil, userInfo: info)
            }
            .store(in: &subscriptions)
    }

    /// Maps Core Data entity changes into lane kicks. We rely on
    /// per-lane throttle so rapid changes don’t spam Nightscout.
    func wireCoreDataSubscribers() {
        coreDataPublisher?
            .filteredByEntityName("OrefDetermination")
            .sink { [weak self] _ in self?.kick(.deviceStatus) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("OverrideStored")
            .sink { [weak self] _ in self?.kick(.overrides) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("OverrideRunStored")
            .sink { [weak self] _ in self?.kick(.overrides) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("TempTargetStored")
            .sink { [weak self] _ in self?.kick(.tempTargets) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("TempTargetRunStored")
            .sink { [weak self] _ in self?.kick(.tempTargets) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("PumpEventStored")
            .sink { [weak self] _ in self?.kick(.pumpHistory) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("CarbEntryStored")
            .sink { [weak self] _ in self?.kick(.carbs) }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("GlucoseStored")
            .sink { [weak self] _ in
                self?.kick(.glucose)
                self?.kick(.manualGlucose)
            }
            .store(in: &subscriptions)
    }

    /// Glucose storage updates → kick glucose lane
    func wireGlucoseStorageSubscriber() {
        glucoseStorage.updatePublisher
            .receive(on: queue)
            .sink { [weak self] _ in
                self?.kick(.glucose)
            }
            .store(in: &subscriptions)
    }
}
