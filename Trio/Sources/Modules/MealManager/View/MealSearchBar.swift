import SwiftUI

extension MealManager {
    /// The meal search field, shared by the Treatments screen and the Meal Manager sheet.
    ///
    /// It talks to the state model directly rather than taking `onChange`/`onClear` closures:
    /// both call sites passed the same reset code, written out twice each.
    struct MealSearchBar: View {
        @ObservedObject var state: StateModel
        var isFocused: FocusState<Bool>.Binding

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(String(localized: "Search foods..."), text: $state.searchQuery)
                    .focused(isFocused)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { state.performFoodSearch() }
                    // Stale results must not outlive the query they came from.
                    .onChange(of: state.searchQuery) { _, _ in state.resetSearchResults() }

                if !state.searchQuery.isEmpty {
                    Button {
                        state.clearSearch()
                        isFocused.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // A `.keyboard` toolbar is installed for the whole keyboard session, not just this
            // field, so declaring one here fought with the toolbars TextFieldWithToolBar puts up
            // for the carbs/fat/protein fields on the same screen. The clear button above and
            // the return key cover what it offered.
        }
    }
}
