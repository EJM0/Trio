import CoreData
import SwiftUI

extension MealManager {
    /// The search results shown under the meal search bar, shared by the Treatments screen and
    /// the Meal Manager sheet. Both used to carry their own near-identical copy of this.
    ///
    /// Two independent sources feed it:
    /// - saved meal presets, filtered live from Core Data, shown when `displayPresets` is on
    /// - OpenFoodFacts hits, shown when `isScannerEnabled` is on
    ///
    /// so turning the barcode scanner off leaves local preset search working.
    struct SearchResults: View {
        /// The two call sites differ only in their container: one is a `List`, the other a `VStack`.
        enum Layout {
            case list
            case stack
        }

        @ObservedObject var state: StateModel
        var layout: Layout = .stack
        let onSelect: (FoodItem) -> Void

        @FetchRequest(
            entity: MealPresetStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "dish", ascending: true)]
        ) private var presets: FetchedResults<MealPresetStored>

        private var query: String {
            state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var matchingPresets: [MealPresetStored] {
            guard state.displayPresets, !query.isEmpty else { return [] }
            return presets.filter { ($0.dish ?? "").localizedCaseInsensitiveContains(query) }
        }

        var body: some View {
            Group {
                ForEach(matchingPresets) { preset in
                    row {
                        FoodSearchResultRow(item: FoodItem(preset: preset), isPreset: true) {
                            onSelect(FoodItem(preset: preset))
                        }
                    }
                }

                if state.isSearching {
                    row {
                        HStack {
                            Spacer()
                            ProgressView().padding(.vertical, 8)
                            Spacer()
                        }
                    }
                } else if let error = state.searchError {
                    row {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            // A search that failed on a flaky connection used to be a dead end.
                            Button(String(localized: "Retry"), action: state.performFoodSearch)
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                        }
                    }
                } else {
                    // Deliberately not wrapped in `withAnimation`: every caller clears the
                    // search, which collapses this whole block, so animating the selection
                    // animated the entire result list sliding away along with the row that was
                    // tapped and the meal list growing underneath it, all at once.
                    ForEach(state.searchResults) { item in
                        row {
                            FoodSearchResultRow(item: item) {
                                onSelect(item)
                            }
                        }
                    }

                    if state.hasMoreSearchResults {
                        row {
                            Button {
                                state.loadMoreSearchResults()
                            } label: {
                                HStack {
                                    if state.isLoadingMoreSearchResults {
                                        ProgressView().scaleEffect(0.9)
                                    } else {
                                        Text("Show \(state.searchPageSize) more results")
                                            .font(.caption.weight(.medium))
                                        Image(systemName: "chevron.down").font(.caption)
                                    }
                                }
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .disabled(state.isLoadingMoreSearchResults)
                        }
                    }
                }
            }
        }

        /// Applies whichever separator/inset treatment the surrounding container needs.
        @ViewBuilder private func row(@ViewBuilder _ content: () -> some View) -> some View {
            switch layout {
            case .list:
                content()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            case .stack:
                content()
                Divider().opacity(0.3)
            }
        }
    }
}
