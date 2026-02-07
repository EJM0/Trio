extension BarcodeScanner {
    final class Provider: BaseProvider, BarcodeScannerProvider {
        @Injected() private var injectedScaleManager: ScaleManager!

        var scaleManager: ScaleManager { injectedScaleManager }
    }
}
