extension BolusCalculatorConfig {
    final class Provider: BaseProvider, BolusCalculatorConfigProvider {
        @Injected() private var injectedScaleManager: ScaleManager!

        var scaleManager: ScaleManager { injectedScaleManager }
    }
}
