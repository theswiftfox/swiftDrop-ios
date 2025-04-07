//
//  SwiftDrop.swift
//  swiftDrop
//
//  Created by Elena Gantner on 06.04.25.
//

import UIKit

import CoreBluetooth
import Foundation

let SERVICE_UUID = CBUUID(string:"35990ca1-d35d-4380-8f4f-ff456c6c6100")
let PSM: CBL2CAPPSM = 0x83
let SERVER_HELLO: [UInt8] = [0xFF, 0x53, 0x77, 0x69, 0x66, 0x74, 0x44, 0x72, 0x6F, 0x70]
let CLIENT_HELLO: [UInt8] = [0xF0, 0x53, 0x77, 0x69, 0x66, 0x74, 0x44, 0x72, 0x6F, 0x70]

let METADATA_ID: UInt8 = 0xFA
let CHUNK_ID: UInt8 = 0xFC
let TRANSFER_COMPLETE_ID: UInt8 = 0xFF

let SERVER_ACK: UInt8 = 0xAC

class MetaData : Codable {
    let filename: String
    let checksum: String
    
    let chunkCount: Int
    
    init(filename: String, checksum: String, chunkCount: Int) {
        self.filename = filename
        self.checksum = checksum
        self.chunkCount = chunkCount
    }
}

enum Error : Swift.Error {
    case writeError(message: String)
    case readError(message: String)
    case compressionError(message: String)
}

@Observable
class SwiftDrop: NSObject {
    private var centralCon: CBCentralManager!
    
    public var discoveredDevices: [CBPeripheral] = []
    
    var table_view: UITableView?
    
    public init(view: UITableView) {
        super.init()
        self.centralCon = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background))
        self.table_view = view
        
        for device in self.centralCon.retrieveConnectedPeripherals(withServices: [SERVICE_UUID]) {
            self.discoveredDevices.append(device)
            table_view?.reloadData()
        }
    }
    
    public func state() -> CBManagerState {
        return self.centralCon.state
    }
    
    public func connect(device: CBPeripheral) {
        self.centralCon.connect(device, options: nil)
    }
    
    public func disconnect(device: CBPeripheral) {
        self.centralCon.cancelPeripheralConnection(device)
    }
}

extension SwiftDrop: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
            case .poweredOff:
                print("Bluetooth is powered off.")
            case .poweredOn:
                print("Bluetooth is powered on. Starting scan...")
                // Start scanning for peripherals or perform other actions
            self.centralCon.scanForPeripherals(withServices: [SERVICE_UUID], options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true,
            ])
            case .resetting:
                print("Bluetooth is resetting.")
            case .unauthorized:
                print("Bluetooth is unauthorized.")
            case .unsupported:
                print("Bluetooth is unsupported on this device.")
            case .unknown:
                print("Bluetooth state is unknown.")
            @unknown default:
                print("A new state is available that is not handled.")
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let alreadyPresent = self.discoveredDevices.contains { element in
            return element.identifier == peripheral.identifier
        }
        if !alreadyPresent {
            self.discoveredDevices.append(peripheral)
            print("Discovered \(peripheral.name ?? "Unknown") (\(peripheral.identifier))")
            DispatchQueue.main.async {
                self.table_view?.reloadData()
            }
        }
    }
}

class L2CapChannelDelegate : NSObject, CBPeripheralDelegate, StreamDelegate {
    private var peripheral: CBPeripheral?
    private var l2capChannel: CBL2CAPChannel?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    
    var mtu: Int = 0
    private var buffer: UnsafeMutableBufferPointer<UInt8>?
    
    private var isConnected: Bool = false
    private var hasData: Bool = false
    
    func startL2CAPConnection(with peripheral: CBPeripheral, psm: CBL2CAPPSM) {
            self.peripheral = peripheral
            self.peripheral?.delegate = self
            self.peripheral?.openL2CAPChannel(psm)
        }

    @objc(peripheral:didOpenL2CAPChannel:error:)
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Swift.Error?) {
        if let error = error {
            print("Failed to open L2CAP channel: \(error.localizedDescription)")
            return
        }

        guard let channel = channel else {
            print("Channel is nil")
            return
        }

        self.l2capChannel = channel
        print("L2CAP channel opened successfully: \(channel)")
        self.isConnected = true
        
        self.inputStream = channel.inputStream
        self.outputStream = channel.outputStream

        // Set the delegate for the streams
        self.inputStream?.delegate = self
        self.outputStream?.delegate = self

        // Open the streams
        self.inputStream?.open()
        self.outputStream?.open()

        // Schedule the streams on the current run loop
        self.inputStream?.schedule(in: RunLoop.current, forMode: .default)
        self.outputStream?.schedule(in: RunLoop.current, forMode: .default)
        
        self.mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        self.buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: mtu)
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
            switch eventCode {
            case .openCompleted:
                print("Stream opened")
            case .hasBytesAvailable:
                if aStream == inputStream {
                    self.hasData = true
                }
            case .hasSpaceAvailable:
                if aStream == outputStream {
                    // You can write data here if needed
                }
            case .errorOccurred:
                print("Stream error occurred: \(aStream.streamError?.localizedDescription ?? "Unknown error")")
            case .endEncountered:
                print("Stream end encountered")
                aStream.close()
                aStream.remove(from: RunLoop.current, forMode: .default)
            default:
                break
            }
        }
    
    public func connected() -> Bool {
        return self.isConnected
    }
    
    public func hasDataAvailable() -> Bool {
        return self.hasData
    }
    
    public func readBytes() throws -> Array<UInt8> {
        guard self.isConnected else {
            throw Error.readError(message: "Not connected to server")
        }
        
        let read = self.inputStream!.read(self.buffer!.baseAddress!, maxLength: self.mtu)
        if read == 0 {
            throw Error.readError(message: "Failed to read SERVER HELLO")
        }
        
        self.hasData = inputStream?.hasBytesAvailable ?? false
        return Array(self.buffer![0..<read])
    }
    
    public func writeBytes(_ bytes: Array<UInt8>) throws {
        guard self.isConnected else {
            throw Error.writeError(message: "Not connected to server")
        }
        
        let writtenBytes = self.outputStream!.write(bytes, maxLength: bytes.count)
        guard writtenBytes > 0 else {
            throw Error.writeError(message: "Failed to write bytes")
        }
        guard writtenBytes == bytes.count else {
            throw Error.writeError(message: "Failed to write all bytes")
        }
    }
}
