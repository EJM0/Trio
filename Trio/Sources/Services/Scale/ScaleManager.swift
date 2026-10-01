import CoreBluetooth
import Foundation
import Swinject

/// A scale seen while pairing.
struct ScaleCandidate: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

protocol ScaleManager {
    /// Reports every scale in range until `stopPairingScan()`, so settings can pick one.
    func startPairingScan(onFound: @escaping (ScaleCandidate) -> Void)
    func stopPairingScan()

    /// Streams weight and battery until `disconnect()`. Drops are reconnected on their own;
    /// `onConnectionChange` only reports them.
    func connect(
        onWeight: @escaping (Double) -> Void,
        onBattery: @escaping (Int) -> Void,
        onConnectionChange: @escaping (Bool) -> Void
    )
    func disconnect()

    func tare()
    func calibrate(weight: Decimal)
}

/// The kitchen scale over BLE. Weight is a float32 LE notify, commands are ASCII writes,
/// battery is the standard Battery Service. Only the scale paired in settings is ever connected,
/// so several scales can share a kitchen.
final class BaseScaleManager: NSObject, ScaleManager, Injectable {
    @Injected() var settingsManager: SettingsManager!

    // ponytail: keep in step with the UUIDs in scale.ino.
    private static let scaleService = CBUUID(string: "0160D9AA-9E50-4E04-A6C7-2EE8C6F7BDF2")
    private static let weightChar = CBUUID(string: "1640D36C-FB0F-4146-8686-A465B2183092")
    private static let controlChar = CBUUID(string: "159939B1-30D1-40A3-B742-697D42E188B5")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryChar = CBUUID(string: "2A19")

    /// How long a command waits for the scale to show up before it is dropped. A tare that
    /// lands minutes later, whenever the scale happens to wake, would zero a loaded pan.
    private static let commandTimeout: TimeInterval = 10

    // Lazy so Bluetooth is not touched until the scale is actually used.
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var pendingCommands: [String] = []

    private var onWeight: ((Double) -> Void)?
    private var onBattery: ((Int) -> Void)?
    private var onConnectionChange: ((Bool) -> Void)?
    private var onFound: ((ScaleCandidate) -> Void)?
    private var isStreaming: Bool { onWeight != nil }

    private var pairedID: UUID? { UUID(uuidString: settingsManager.settings.scaleID) }

    init(resolver: Resolver) {
        super.init()
        injectServices(resolver)
    }

    func startPairingScan(onFound: @escaping (ScaleCandidate) -> Void) {
        self.onFound = onFound
        scanIfPossible()
    }

    func stopPairingScan() {
        onFound = nil
        // Keep scanning only while the paired scale itself still has to be found that way.
        let stillLooking = peripheral == nil && (isStreaming || !pendingCommands.isEmpty)
        if !stillLooking { central.stopScan() }
    }

    func connect(
        onWeight: @escaping (Double) -> Void,
        onBattery: @escaping (Int) -> Void,
        onConnectionChange: @escaping (Bool) -> Void
    ) {
        self.onWeight = onWeight
        self.onBattery = onBattery
        self.onConnectionChange = onConnectionChange
        start()
    }

    func disconnect() {
        onWeight = nil
        onBattery = nil
        onConnectionChange = nil
        stopIfIdle()
    }

    func tare() { send("t") }

    func calibrate(weight: Decimal) {
        send("c" + NSDecimalNumber(decimal: weight).description(withLocale: Locale(identifier: "en_US")))
    }

    // MARK: - Link

    private func send(_ command: String) {
        if let control, let peripheral {
            peripheral.writeValue(Data(command.utf8), for: control, type: .withResponse)
            return
        }
        pendingCommands.append(command)
        start()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandTimeout) { [weak self] in
            guard let self, self.control == nil else { return }
            self.pendingCommands.removeAll()
            self.stopIfIdle()
        }
    }

    private func start() {
        guard central.state == .poweredOn, let pairedID else { return } // didUpdateState picks it up
        if peripheral?.identifier != pairedID {
            // Paired with another scale since the last link: let the old one go.
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            peripheral = central.retrievePeripherals(withIdentifiers: [pairedID]).first
            peripheral?.delegate = self
            control = nil
        }
        if let peripheral {
            // A pending connect never times out, so this also covers a scale that is asleep.
            if peripheral.state == .disconnected { central.connect(peripheral) }
        } else {
            // iOS has forgotten it; find it by advertisement instead.
            scanIfPossible()
        }
    }

    private func scanIfPossible() {
        guard central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [Self.scaleService])
    }

    private func stopIfIdle() {
        guard !isStreaming, pendingCommands.isEmpty else { return }
        if onFound == nil { central.stopScan() } // settings is still listing scales
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        control = nil
    }
}

extension BaseScaleManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        if isStreaming || !pendingCommands.isEmpty { start() }
        if onFound != nil { scanIfPossible() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "scale"
        onFound?(ScaleCandidate(id: peripheral.identifier, name: name, rssi: rssi.intValue))

        guard peripheral.identifier == pairedID, self.peripheral == nil,
              isStreaming || !pendingCommands.isEmpty else { return }
        if onFound == nil { central.stopScan() }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debug(.service, "Scale connected")
        onConnectionChange?(true)
        peripheral.discoverServices([Self.scaleService, Self.batteryService])
    }

    func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error _: Error?) {
        start()
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        debug(.service, "Scale disconnected: \(error?.localizedDescription ?? "on request")")
        control = nil
        onConnectionChange?(false)
        if isStreaming { start() }
    }
}

extension BaseScaleManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices _: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error _: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.batteryChar,
                 Self.weightChar:
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case Self.controlChar:
                control = characteristic
                let queued = pendingCommands
                pendingCommands.removeAll()
                queued.forEach(send)
            default:
                break
            }
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error _: Error?) {
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.weightChar where data.count == 4:
            let weight = Float(bitPattern: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            onWeight?(max(0, Double(weight)))
        case Self.batteryChar where !data.isEmpty:
            onBattery?(Int(data[data.startIndex]))
        default:
            break
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor _: CBCharacteristic, error _: Error?) {
        // A command sent from settings opened the link only for itself.
        stopIfIdle()
    }
}
