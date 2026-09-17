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

        /// True while either Treatments route is the presented modal.
        private var isShowingTreatments: Bool {
            guard let screen = modal?.screen else { return false }
            return screen == .treatmentView || screen == .treatmentWithScanner
        }

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

            // Subscribe to MealManager shortcut notification.
            //
            // Only route when Treatments is not already up. If it is, re-sending would either be
            // swallowed by the de-duplication above (same screen) or tear the screen down and
            // rebuild it, losing anything already typed -- so Treatments.RootView listens for the
            // same notification itself and just presents the sheet.
            //
            // Which tab opens is decided there too, since it depends on whether the barcode
            // scanner is enabled.
            Foundation.NotificationCenter.default.publisher(for: .openBarcode)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, !self.isShowingTreatments else { return }
                    self.router.mainModalScreen.send(.treatmentWithScanner)
                }
                .store(in: &lifetime)
        }
    }
}
