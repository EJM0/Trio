import Combine
import CoreData
import Foundation

extension BaseNightscoutManager {
    func wireSubscribers() {
        wireExternalUploadRequests()
        wireCoreDataSubscribers()
        wireGlucoseStorageSubscriber()
    }

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

    // MARK: 3) Glucose storage tick → kick glucose lane

    func wireGlucoseStorageSubscriber() {
        glucoseStorage.updatePublisher
            .receive(on: queue)
            .sink { [weak self] _ in
                self?.kick(.glucose)
            }
            .store(in: &subscriptions)
    }
}
