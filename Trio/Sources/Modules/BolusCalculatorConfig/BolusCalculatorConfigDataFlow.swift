enum BolusCalculatorConfig {
    enum Config {}
}

protocol BolusCalculatorConfigProvider {
    var scaleManager: ScaleManager { get }
    var openFoodFacts: OpenFoodFactsClient { get }
}
