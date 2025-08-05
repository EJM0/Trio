import Combine
import CoreData
import Foundation
import Swinject

protocol IOBService {
    var iobPublisher: AnyPublisher<Decimal?, Never> { get }
    var currentIOB: Decimal? { get }
    func updateIOB()
}

final class BaseIOBService: IOBService, Injectable {
    @Injected() private var fileStorage: FileStorage!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var apsManager: APSManager!

    private let iobSubject = CurrentValueSubject<Decimal?, Never>(nil)
    var iobPublisher: AnyPublisher<Decimal?, Never> {
        iobSubject.eraseToAnyPublisher()
    }

    var currentIOB: Decimal? {
        lookupIOB()
    }

    private var subscriptions = Set<AnyCancellable>()
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private let queue = DispatchQueue(label: "BaseIOBService.queue", qos: .background)
    private let context = CoreDataStack.shared.newTaskContext()

    init(resolver: Resolver) {
        injectServices(resolver)
        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()
        subscribe()
    }

    private func subscribe() {
        // Trigger update when a new determination is available
        coreDataPublisher?.filteredByEntityName("OrefDetermination").sink { [weak self] _ in
            print("IOB-FILE: Determination update")
            self?.updateIOB()
        }.store(in: &subscriptions)

        // Trigger update when the iob file is updated
        apsManager.iobFileDidUpdate
            .sink { [weak self] _ in
                print("IOB-FILE: apsManager update")
                self?.updateIOB()
            }
            .store(in: &subscriptions)
    }

    private func fetchLatestDeterminationIOB() -> (iob: Decimal?, date: Date?) {
        var iob: Decimal?
        var date: Date?
        context.performAndWait {
            let request = OrefDetermination.fetchRequest() as NSFetchRequest<OrefDetermination>
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: false)]
            request.fetchLimit = 1
            if let determination = try? context.fetch(request).first {
                iob = determination.iob as? Decimal
                date = determination.deliverAt
            }
        }
        return (iob, date)
    }

    func lookupIOB() -> Decimal? {
        let iobFromFile = fileStorage.retrieve(OpenAPS.Monitor.iob, as: [IOBEntry].self)
        let iobFromFileValue = iobFromFile?.first?.iob
        let iobFromFileDate = iobFromFile?.first?.time

        let (iobFromDetermination, iobFromDeterminationDate) = fetchLatestDeterminationIOB()

        var mostRecentIOB: Decimal?

        if let iobFromFileValue = iobFromFileValue, let iobFromFileDate = iobFromFileDate {
            if let iobFromDetermination = iobFromDetermination, let iobFromDeterminationDate = iobFromDeterminationDate {
                if iobFromFileDate > iobFromDeterminationDate {
                    mostRecentIOB = iobFromFileValue
                } else {
                    mostRecentIOB = iobFromDetermination
                }
            } else {
                mostRecentIOB = iobFromFileValue
            }
        } else {
            mostRecentIOB = iobFromDetermination
        }

        return mostRecentIOB
    }

    func updateIOB() {
        Task {
            let mostRecentIOB = lookupIOB()
            if iobSubject.value != mostRecentIOB {
                iobSubject.send(mostRecentIOB)
            }
        }
    }
}
