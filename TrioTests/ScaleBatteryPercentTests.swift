import Testing

@testable import Trio

/// The scale reports `{"voltage":…,"percent":…}`; Trio must show the `percent` the scale itself
/// displays. This covers the fallback used when firmware sends volts without a percent, which
/// mirrors the firmware's own `battPercent()` (linear BAT_EMPTY 3.30V -> BAT_FULL 4.20V).
@Suite("Scale battery percentage from voltage") struct ScaleBatteryPercentTests {
    @Test("Agrees with the firmware's own assertions")  func matchesFirmware() {
        // These mirror selfTest() in scale.ino; if they diverge, phone and scale disagree again.
        #expect(BaseScaleManager.batteryPercent(forVoltage: 4.30) == 100)
        #expect(BaseScaleManager.batteryPercent(forVoltage: 3.20) == 0)
        #expect(BaseScaleManager.batteryPercent(forVoltage: 3.75) == 50)
    }

    @Test("Clamps outside the cell's range")  func clamps() {
        #expect(BaseScaleManager.batteryPercent(forVoltage: 4.20) == 100)
        #expect(BaseScaleManager.batteryPercent(forVoltage: 3.30) == 0)
        #expect(BaseScaleManager.batteryPercent(forVoltage: 2.50) == 0)
    }

    @Test("Never leaves 0...100")  func staysInRange() {
        for millivolts in 2500 ... 4400 {
            #expect((0 ... 100).contains(BaseScaleManager.batteryPercent(forVoltage: Double(millivolts) / 1000)))
        }
    }

    @Test("Never reads higher as the cell drains")  func isMonotonic() {
        var previous = 101
        for millivolts in stride(from: 4400, through: 2500, by: -1) {
            let pct = BaseScaleManager.batteryPercent(forVoltage: Double(millivolts) / 1000)
            #expect(pct <= previous)
            previous = pct
        }
    }
}
