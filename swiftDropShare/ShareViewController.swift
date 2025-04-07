//
//  ShareViewController.swift
//  swiftDropShare
//
//  Created by Elena Gantner on 06.04.25.
//

import UIKit
import SwiftUI

import MobileCoreServices
import UniformTypeIdentifiers
import CoreBluetooth
import CryptoKit

class DeviceCell: UITableViewCell {
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var iconImageView: UIImageView!
}

class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    @IBOutlet weak var innerView: UIView!
    
    @IBOutlet weak var tableView: UITableView!
    @IBOutlet weak var progressTitle: UILabel!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var progressValue: UILabel!
    @IBOutlet weak var activityView: UIActivityIndicatorView!
    @IBOutlet weak var shareButton: UIButton!
    
    var swiftDrop: SwiftDrop!
    
    var selectedDevice: CBPeripheral?
    var fileURL: URL?
        
    override func viewDidLoad() {
        super.viewDidLoad()
        self.swiftDrop = SwiftDrop(view: self.tableView)
        
        self.progressTitle.isHidden = true
        self.progressView.isHidden = true
        self.progressValue.isHidden = true
        self.activityView.isHidden = false
        self.activityView.startAnimating()
        
        self.tableView.dataSource = self
        self.tableView.delegate = self
        
        self.innerView.layer.cornerRadius = 8
        self.innerView.layer.masksToBounds = true
        
        self.shareButton.isEnabled = false
                
        if extensionContext?.inputItems.count ?? 0 != 1 {
            showAlert(with: "Please select only one file.")
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
        }
        
        if let inputItem = extensionContext?.inputItems[0] as? NSExtensionItem {
            if let attachments = inputItem.attachments {
                for attachment in attachments {
//                        print("Image attachment found: \(String(describing: attachment))")
                    
                    if attachment.hasItemConformingToTypeIdentifier("public.file-url") {
                        attachment.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data,arg in
                            if let fileURL = data as? URL {
                                self.fileURL = fileURL
                            }
                        }
                        continue
                    }
                    if attachment.hasItemConformingToTypeIdentifier("public.heic") {
                        attachment.loadItem(forTypeIdentifier: "public.heic", options: nil) { data,arg  in
                            if let fileURL = data as? URL {
                                self.fileURL = fileURL
                            }
                        }
                        continue
                    }
                    if attachment.hasItemConformingToTypeIdentifier("public.jpeg") {
                        attachment.loadItem(forTypeIdentifier: "public.jpeg", options: nil) { data,arg  in
                            if let fileURL = data as? URL {
                                self.fileURL = fileURL
                            }
                        }
                    }
                }
            }
        }
    }
    
    @IBAction func shareButtonPressed(_ sender: Any) {
        // Start file transfer to selected device
        if let device = selectedDevice, let fileURL = fileURL {
            print("Sending file...")
            DispatchQueue.global(qos: .userInitiated).async {
                self.sendFile(fileURL, to: device)
            }
        } else {
            print("DBG: Device \(String(describing: selectedDevice)) or file URL \(String(describing: fileURL)) is nil")
        }
    }


    // MARK: - UITableViewDataSource
        
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return swiftDrop.discoveredDevices.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DeviceCell", for: indexPath) as! DeviceCell
        let device = swiftDrop.discoveredDevices[indexPath.row]
        cell.nameLabel?.text = device.name ?? "Unknown Device"
        
        return cell
    }
    
    // MARK: - UITableViewDelegate
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedDevice = swiftDrop.discoveredDevices[indexPath.row]
        shareButton.isEnabled = true
    }
    
    // MARK: - File Transfer
    
    func sendFile(_ fileURL: URL, to device: CBPeripheral) {
        DispatchQueue.main.async {
            self.shareButton.isEnabled = false
        }
        
        self.swiftDrop.connect(device: device)
        
        let fileData: Data
        do {
            fileData = try (Data(contentsOf: fileURL))
        } catch {
            showAlert(with: "Unable to open file: \(error)")
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        let compressed: Data
        do {
            compressed = try (fileData as NSData).compressed(using: .lzma) as Data
        } catch {
            showAlert(with: "Unable to compress data before sending. \(error)")
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        let hash = SHA256.hash(data: compressed)
        let checksumStr = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        print("Wait for BT connection...")
        for _ in 1...10 {
            if device.state == .connected {
                break
            }
                            
            Thread.sleep(forTimeInterval: 1.0)
        }
        
        
        if device.state != .connected {
            self.showAlert(with: "Unable to connect after 10s")
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        let l2capChannel = L2CapChannelDelegate()
        l2capChannel.startL2CAPConnection(with: device, psm: PSM)
        
        print("Wait for L2CAP channel connection...")
  
        for _ in 1...10 {
            if l2capChannel.connected() {
                break
            }
            
            Thread.sleep(forTimeInterval: 1.0)
        }

        
        if !l2capChannel.connected() {
            showAlert(with: "Unable to open L2CAP channel after 10s")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        // CLIENT_HELLO -> SERVER_HELLO
        do {
            try l2capChannel.writeBytes(Array(CLIENT_HELLO))
        } catch {
            showAlert(with: "Handshake failed.")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        var bytes: [UInt8]
        do {
            bytes = try l2capChannel.readBytes()
        } catch {
            showAlert(with: "Unable to read handshake response: \(error)")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }

        if bytes.count != SERVER_HELLO.count {
            showAlert(with: "Handshake response length invalid.")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        if bytes != Array(SERVER_HELLO) {
            showAlert(with: "Handshake response was invalid.")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        let chunkLength = l2capChannel.mtu - 1 // 1 byte reserved for msg id
        
        var chunkCount = compressed.count / chunkLength
        if compressed.count % chunkLength != 0 {
            chunkCount = chunkCount + 1
        }
        
        let metadata = MetaData(filename: fileURL.lastPathComponent, checksum: checksumStr, chunkCount: chunkCount)
        
        let jsonData: Data
        do {
            jsonData = try JSONEncoder().encode(metadata)
        } catch {
            showAlert(with: "Unable to serialize metadata to JSON.")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        do {
            try l2capChannel.writeBytes([METADATA_ID] + ([UInt8](jsonData)))
        } catch {
            showAlert(with: "Failed to send Metadata: \(error)")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
            return
        }
        
        // metadata ack
        do {
            let bytes = try l2capChannel.readBytes()
            if bytes.first != SERVER_ACK || bytes.count > 1 {
                showAlert(with: "Unexpected server response on Metadata send.")
                self.swiftDrop.disconnect(device: device)
                DispatchQueue.main.async {
                    self.shareButton.isEnabled = true
                }
                return
            }
        } catch {
            showAlert(with: "Did not receive Metadata ACK")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
            }
        }
        
        DispatchQueue.main.async {            
            self.progressTitle.isHidden = false
            self.progressView.isHidden = false
            self.progressView.progress = 0
            self.progressValue.text = "0/\(chunkCount)"
            self.progressValue.isHidden = false
        }
        
        var chunks: [Data] = []
        // Split the data into chunks
        for i in 0..<chunkCount {
            let start = i * chunkLength
            let end = (i == chunkCount - 1) ? compressed.count : start + chunkLength
            let chunk = compressed.subdata(in: start..<end)
            chunks.append(chunk)
        }
        
        do {
            for (i, chunk) in chunks.enumerated() {
                try l2capChannel.writeBytes([CHUNK_ID] + [UInt8](chunk))
                
                // wait for server to ack the chunk
                let bytes = try l2capChannel.readBytes()
                if bytes.first != SERVER_ACK || bytes.count > 1 {
                    showAlert(with: "Transfer failed: Unexpected server response.")
                    self.swiftDrop.disconnect(device: device)
                    DispatchQueue.main.async {
                        self.shareButton.isEnabled = true
                        
                        self.progressView.isHidden = true
                        self.progressTitle.isHidden = true
                        self.progressValue.isHidden = true
                    }
                    return
                }
                
                DispatchQueue.main.async {
                    self.progressView.setProgress(Float(i + 1) / Float(chunkCount), animated: true)
                    self.progressValue.text = "\(i + 1)/\(chunkCount)"
                }
            }
            
            // send 0xFF to notify send complete
            try l2capChannel.writeBytes([TRANSFER_COMPLETE_ID])

            
            // wait for an ack before exiting to ensure message has been sent.
            let bytes = try l2capChannel.readBytes()
            if bytes.first != SERVER_ACK || bytes.count > 1 {
                showAlert(with: "Transfer failed: Unexpected server response.")
                self.swiftDrop.disconnect(device: device)
                DispatchQueue.main.async {
                    self.shareButton.isEnabled = true
                    
                    self.progressView.isHidden = true
                    self.progressTitle.isHidden = true
                    self.progressValue.isHidden = true
                }
                return
            }
        } catch {
            showAlert(with: "Transfer failed. Connection closed.")
            self.swiftDrop.disconnect(device: device)
            DispatchQueue.main.async {
                self.shareButton.isEnabled = true
                
                self.progressView.isHidden = true
                self.progressTitle.isHidden = true
                self.progressValue.isHidden = true
            }
            return
        }
        
        self.swiftDrop.disconnect(device: device)
        
        DispatchQueue.main.async {
            self.progressView.isHidden = true
            self.progressTitle.isHidden = true
            self.progressValue.isHidden = true
            
            let alertController = UIAlertController(title: "Transfer Complete", message: "File sent successfully!", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
            alertController.addAction(okAction)
            self.present(alertController, animated: true, completion: {
                self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            })
        }
    }
    
    func showAlert(with message: String) {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: "Transfer Failed", message: message, preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default, handler: nil)
            alertController.addAction(okAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
}
