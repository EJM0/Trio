import Foundation

// MARK: - Meal Search

/// Search over saved meal presets and OpenFoodFacts.
///
/// Presets are matched live by `MealManager.SearchResults` from a `@FetchRequest`; everything
/// here is the remote half, which is gated on `isScannerEnabled`. This used to exist twice:
/// once here, and once as private methods on Treatments.RootView.
extension MealManager.StateModel {
    /// Clears the query and every derived piece of search state.
    /// Local meal presets are filtered live from a `@FetchRequest`, so nothing to reset there.
    func clearSearch() {
        searchQuery = ""
        resetSearchResults()
    }

    /// Resets results without touching the query (used when the query itself changes).
    func resetSearchResults() {
        searchResults = []
        searchError = nil
        hasMoreSearchResults = false
        isLoadingMoreSearchResults = false
        isSearching = false
        currentSearchPage = 1
    }

    /// Searches OpenFoodFacts. Local meal presets are matched live by the view regardless;
    /// this is the remote half, so it is a no-op when the scanner feature is off.
    func performFoodSearch() {
        resetSearchResults()

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, isScannerEnabled else { return }

        isSearching = true

        Task { @MainActor in
            do {
                let firstPageResults = try await provider.openFoodFacts.searchProducts(
                    query: query,
                    page: 1,
                    pageSize: searchPageSize
                )
                searchResults = firstPageResults
                hasMoreSearchResults = firstPageResults.count == searchPageSize
            } catch {
                searchError = error.localizedDescription
                searchResults = []
                hasMoreSearchResults = false
            }
            isSearching = false
        }
    }

    func loadMoreSearchResults() {
        guard isScannerEnabled,
              !isSearching,
              !isLoadingMoreSearchResults,
              hasMoreSearchResults
        else {
            return
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            hasMoreSearchResults = false
            return
        }

        isLoadingMoreSearchResults = true
        searchError = nil

        let nextPage = currentSearchPage + 1

        Task { @MainActor in
            defer { isLoadingMoreSearchResults = false }

            do {
                let nextPageResults = try await provider.openFoodFacts.searchProducts(
                    query: query,
                    page: nextPage,
                    pageSize: searchPageSize
                )

                if nextPageResults.isEmpty {
                    hasMoreSearchResults = false
                    return
                }

                searchResults.append(contentsOf: nextPageResults)
                currentSearchPage = nextPage
                hasMoreSearchResults = nextPageResults.count == searchPageSize
            } catch {
                searchError = error.localizedDescription
            }
        }
    }}
