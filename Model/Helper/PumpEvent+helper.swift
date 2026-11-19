import CoreData
import Foundation

extension PumpEventStored {
    static func fetch(_ predicate: NSPredicate, ascending: Bool, fetchLimit: Int? = nil) -> NSFetchRequest<PumpEventStored> {
        let request = PumpEventStored.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: ascending)]
        request.resultType = .managedObjectResultType
        request.predicate = predicate
        if let fetchLimit = fetchLimit {
            request.fetchLimit = fetchLimit
        }
        return request
    }

    // Preview
    @discardableResult static func makePreviewEvents(count: Int, provider: CoreDataStack) -> [PumpEventStored] {
        let context = provider.persistentContainer.viewContext
        let events = (0 ..< count).map { index -> PumpEventStored in
            let event = PumpEventStored(context: context)
            event.id = UUID().uuidString
            event.timestamp = Date.now.addingTimeInterval(Double(index) * -300) // Every 5 minutes
            event.type = EventType.bolus.rawValue
            event.isUploadedToNS = false
            event.isUploadedToHealth = false
            event.isUploadedToTidepool = false

            // Add a bolus
            let bolus = BolusStored(context: context)
            bolus.amount = 2.5 as NSDecimalNumber
            bolus.isExternal = false
            bolus.isSMB = false
            bolus.pumpEvent = event

            return event
        }

        try? context.save()
        return events
    }
}

public extension PumpEventStored {
    enum EventType: String, JSON {
        case bolus = "Bolus"
        case smb = "SMB"
        case isExternal = "External Insulin"
        case mealBolus = "Meal Bolus"
        case correctionBolus = "Correction Bolus"
        case snackBolus = "Snack Bolus"
        case bolusWizard = "BolusWizard"
        case tempBasal = "TempBasal"
        case tempBasalDuration = "TempBasalDuration"
        case pumpSuspend = "PumpSuspend"
        case pumpResume = "PumpResume"
        case pumpAlarm = "PumpAlarm"
        case pumpBattery = "PumpBattery"
        case rewind = "Rewind"
        case prime = "Prime"
        case journalCarbs = "JournalEntryMealMarker"
        case siteChange = "SiteChange"

        case nsNote = "Note"
        case nsTempBasal = "Temp Basal"
        case nsCarbCorrection = "Carb Correction"
        case nsTempTarget = "Temporary Target"
        case nsInsulinChange = "Insulin Change"
        case nsSiteChange = "Site Change"
        case nsBatteryChange = "Pump Battery Change"
        case nsAnnouncement = "Announcement"
        case nsSensorChange = "Sensor Start"
        case nsExercise = "Exercise"
        case capillaryGlucose = "BG Check"
    }

    enum TempType: String, JSON {
        case absolute
        case percent
    }
}

extension NSPredicate {
    // NULL-tolerant: the keypath's LEFT JOIN drops bolus rows under NOT (... == YES)
    static let notScheduledBasal = "(tempBasal == nil OR tempBasal.isScheduledBasal == NO)"

    private static let notMutable = "isMutable == NO"

    static var pumpHistoryLast1440Minutes: NSPredicate { pumpHistoryLast1440Minutes(now: Date()) }

    static func pumpHistoryLast1440Minutes(now: Date) -> NSPredicate {
        let date = OrefInputs.pumpHistoryStart(now: now)
        return NSPredicate(format: "timestamp >= %@ AND \(notScheduledBasal)", date as NSDate)
    }

    static var pumpHistoryLast48h: NSPredicate { pumpHistoryLast48h(now: Date()) }

    static func pumpHistoryLast48h(now: Date) -> NSPredicate {
        let date = OrefInputs.orphanedResumeWindowStart(now: now)
        return NSPredicate(format: "timestamp >= %@ AND \(notScheduledBasal)", date as NSDate)
    }

    static var pumpHistoryLast24h: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(format: "timestamp >= %@", date as NSDate)
    }

    static func pumpHistory(since date: Date) -> NSPredicate {
        NSPredicate(format: "timestamp >= %@", date as NSDate)
    }

    static var pumpHistoryForStats: NSPredicate {
        let date = Date.threeMonthsAgo
        return NSPredicate(format: "pumpEvent.timestamp >= %@", date as NSDate)
    }

    static var recentPumpHistory: NSPredicate {
        let date = Date.twentyMinutesAgo
        return NSPredicate(
            format: "type == %@ AND timestamp >= %@ AND \(notScheduledBasal)",
            PumpEventStored.EventType.tempBasal.rawValue,
            date as NSDate
        )
    }

    static var lastPumpBolus: NSPredicate {
        let date = Date.twentyMinutesAgo
        return NSPredicate(format: "timestamp >= %@ AND bolus.isExternal == %@", date as NSDate, false as NSNumber)
    }

    static func duplicates(_ date: Date) -> NSPredicate {
        NSPredicate(format: "timestamp == %@", date as NSDate)
    }

    // Mutable rows upload immediately; value changes reset isUploadedToNS and
    // the re-POST replaces the NS document (upsert on created_at + eventType).
    static var pumpEventsNotYetUploadedToNightscout: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(
            format: "timestamp >= %@ AND isUploadedToNS == %@ AND \(notScheduledBasal)",
            date as NSDate,
            false as NSNumber
        )
    }

    static var pumpEventsNotYetUploadedToHealth: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(
            format: "timestamp >= %@ AND isUploadedToHealth == %@ AND \(notScheduledBasal) AND \(notMutable)",
            date as NSDate,
            false as NSNumber
        )
    }

    static var pumpEventsNotYetUploadedToTidepool: NSPredicate {
        let date = Date.oneDayAgo
        return NSPredicate(
            format: "timestamp >= %@ AND isUploadedToTidepool == %@ AND \(notScheduledBasal) AND \(notMutable)",
            date as NSDate,
            false as NSNumber
        )
    }
}

// MARK: - Native mapping

extension PumpEventStored {
    /// Converts a stored pump event into the `PumpHistoryEvent`s the oref algorithm can use.
    /// A temp basal yields a duration entry followed by a rate entry.
    func toPumpHistoryEvents() -> [PumpHistoryEvent] {
        OrefInputs.pumpHistoryEvents(
            id: id,
            timestamp: timestamp,
            type: type,
            bolus: bolus.map { (amount: $0.amount?.doubleValue, isSMB: $0.isSMB, isExternal: $0.isExternal) },
            tempBasal: tempBasal.map { (duration: Int($0.duration), rate: $0.rate?.doubleValue, tempType: $0.tempType) }
        )
    }
}
