import Combine
import LoopKitUI
import SwiftUI
import Swinject

extension Main {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var apsManager: APSManager!
        @Injected() var alertPermissionsChecker: AlertPermissionsChecker!
        @Injected() var broadcaster: Broadcaster!
        @Published var modal: Modal?
        @Published var secondaryModal: SecondaryModalWrapper?

        override func subscribe() {
            router.mainModalScreen
                .map { $0?.modal(resolver: self.resolver!) }
                .removeDuplicates { $0?.id == $1?.id }
                .receive(on: DispatchQueue.main)
                .assign(to: &$modal)

            $modal
                .removeDuplicates { $0?.id == $1?.id }
                .filter { $0 == nil }
                .sink { _ in
                    self.router.mainModalScreen.send(nil)
                }
                .store(in: &lifetime)

            router.mainSecondaryModalView
                .receive(on: DispatchQueue.main)
                .sink { view in
                    self.secondaryModal = view.map { SecondaryModalWrapper(view: $0) }
                }
                .store(in: &lifetime)

            $secondaryModal
                .removeDuplicates { $0?.id == $1?.id }
                .filter { $0 == nil }
                .sink { _ in
                    self.router.mainSecondaryModalView.send(nil)
                }
                .store(in: &lifetime)

            // Subscribe to BarcodeScanner shortcut notification
            Foundation.NotificationCenter.default.publisher(for: .openBarcode)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.router.mainModalScreen.send(.treatmentWithScanner)
                }
                .store(in: &lifetime)
        }
    }
}
