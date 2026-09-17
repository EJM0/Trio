extension MealManager {
    final class Provider: BaseProvider, MealManagerProvider {
        @Injected() private var injectedScaleManager: ScaleManager!
        @Injected() private var injectedOpenFoodFacts: OpenFoodFactsClient!

        var scaleManager: ScaleManager { injectedScaleManager }
        var openFoodFacts: OpenFoodFactsClient { injectedOpenFoodFacts }
    }
}
