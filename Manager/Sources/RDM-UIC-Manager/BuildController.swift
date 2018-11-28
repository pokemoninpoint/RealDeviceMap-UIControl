//
//  BuildController.swift
//  RDM-UIC-Manager
//
//  Created by Florian Kostenzer on 28.11.18.
//

import Foundation
import PerfectLib
import PerfectThread

class BuildController {
    
    public static var global = BuildController()
    
    private var devicesLock = Threading.Lock()
    private var devicesToRemove = [Device]()
    private var devicesToAdd = [Device]()
    
    private var managerQueue: ThreadQueue!
    
    private var activeDeviceLock = Threading.Lock()
    private var activeDevices = [Device]()
    
    private var path: String = ""
    private var timeout: Int = 60
    
    public func start(path: String, timeout: Int) {
        
        self.path = path
        self.timeout = timeout
        
        Log.info(message: "Building Project...")
        let xcodebuild = Shell("xcodebuild", "build-for-testing", "-workspace", "\(path)/RealDeviceMap-UIControl.xcworkspace", "-scheme", "RealDeviceMap-UIControl", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration")
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        _ = xcodebuild.run(outputPipe: outputPipe, errorPipe: errorPipe)
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if error.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
            Log.terminal(message: "Building Project Failed!\n\(error)")
        }
        Log.info(message: "Building Project done")
        
        devicesLock.lock()
        devicesToAdd = Device.getAll()
        devicesLock.unlock()
        managerQueue = Threading.getQueue(name: "BuildController-Manager", type: .serial)
        managerQueue.dispatch(managerQueueRun)
    }
    
    public func addDevice(device: Device) {
        devicesLock.lock()
        devicesToAdd.append(device)
        devicesLock.unlock()
    }
    
    public func removeDevice(device: Device) {
        devicesLock.lock()
        devicesToRemove.append(device)
        devicesLock.unlock()
    }
    
    private func managerQueueRun() {
        while true {
            devicesLock.lock()
            let devicesToAdd = self.devicesToAdd
            let devicesToRemove = self.devicesToRemove
            self.devicesToAdd = [Device]()
            self.devicesToRemove = [Device]()
            devicesLock.unlock()
            
            for device in devicesToRemove {
                let queue = Threading.getQueue(name: "BuildController-\(device.uuid)", type: .serial)
                activeDeviceLock.lock()
                if let index = activeDevices.index(of: device) {
                    activeDevices.remove(at: index)
                }
                activeDeviceLock.unlock()
                Threading.destroyQueue(queue)
            }
            
            for device in devicesToAdd {
                let queue = Threading.getQueue(name: "BuildController-\(device.uuid)", type: .serial)
                activeDeviceLock.lock()
                activeDevices.append(device)
                activeDeviceLock.unlock()
                queue.dispatch {
                    self.deviceQueueRun(device: device)
                }
            }
            
            Threading.sleep(seconds: 1)
        }
    }
    
    private func deviceQueueRun(device: Device) {
        
        Log.info(message: "Starting \(device.name)'s Manager")
        
        let xcodebuild = Shell("xcodebuild", "test-without-building", "-workspace", "\(path)/RealDeviceMap-UIControl.xcworkspace", "-scheme", "RealDeviceMap-UIControl", "-destination", "id=\(device.uuid)", "-allowProvisioningUpdates", "-destination-timeout", "\(timeout)",
            "name=\(device.name)", "backendURL=\(device.backendURL)", "enableAccountManager=\(device.enableAccountManager)", "port=\(device.port)", "pokemonMaxTime=\(device.pokemonMaxTime)", "raidMaxTime=\(device.raidMaxTime)", "maxWarningTimeRaid=\(device.maxWarningTimeRaid)", "delayMultiplier=\(device.delayMultiplier)", "jitterValue=\(device.jitterValue)", "targetMaxDistance=\(device.targetMaxDistance)", "itemFullCount=\(device.itemFullCount)", "questFullCount=\(device.questFullCount)", "itemsPerStop=\(device.itemsPerStop)", "minDelayLogout=\(device.minDelayLogout)", "maxNoQuestCount=\(device.maxNoQuestCount)", "maxFailedCount=\(device.maxFailedCount)", "maxEmptyGMO=\(device.maxEmptyGMO)", "startupLocationLat=\(device.startupLocationLat)", "startupLocationLon=\(device.startupLocationLon)", "encoutnerMaxWait=\(device.encoutnerMaxWait)"
        )

        var contains = true
        
        let lastChangedLock = Threading.Lock()
        var lastChanged = Date()
        var task: Process?
        let xcodebuildQueue = Threading.getQueue(name: "BuildController-\(device.uuid)-runner", type: .serial)
        xcodebuildQueue.dispatch {
            while contains {
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                
                let timestamp = Int(Date().timeIntervalSince1970)
                let fullLog = FileLogger(file: "./logs/\(timestamp)-xcodebuild.full.log")
                let debugLog = FileLogger(file: "./logs/\(timestamp)-xcodebuild.debug.log")

                task = xcodebuild.run(outputPipe: outputPipe, errorPipe: errorPipe)
                
                Log.info(message: "Starting xcodebuild for \(device.name)")
                lastChangedLock.lock()
                lastChanged = Date()
                lastChangedLock.unlock()
                outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let string = String(data: fileHandle.availableData, encoding: .utf8)
                    if string != nil && string!.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
                        fullLog.uic(message: string!, all: true)
                        debugLog.uic(message: string!, all: false)
                        lastChangedLock.lock()
                        lastChanged = Date()
                        lastChangedLock.unlock()
                    }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let string = String(data: fileHandle.availableData, encoding: .utf8)
                    if string != nil && string!.trimmingCharacters(in: .whitespacesAndNewlines) != "" {
                        fullLog.uic(message: string!, all: true)
                        debugLog.uic(message: string!, all: false)
                        lastChangedLock.lock()
                        lastChanged = Date()
                        lastChangedLock.unlock()
                    }

                }
                task?.waitUntilExit()
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                Threading.sleep(seconds: 1.0)
            }
            task?.suspend()
        }
        
        while contains {
            
            lastChangedLock.lock()
            if Int(Date().timeIntervalSince(lastChanged)) >= timeout {
                task!.terminate()
                Log.info(message: "Stopping \(device.name)'s Task. No output for over \(timeout)s")
            }
            lastChangedLock.unlock()
            
            Threading.sleep(seconds: 5.0)
            activeDeviceLock.lock()
            contains = activeDevices.contains(device)
            activeDeviceLock.unlock()
        }
        task?.terminate()
        Threading.destroyQueue(xcodebuildQueue)
        Log.info(message: "Stopping \(device.name)'s Manager")
    }
    
}
