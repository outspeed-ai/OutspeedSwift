import Foundation
import DeviceKit
import os.log
import AVFoundation

/// Utility class for device-specific functionality
public class DeviceUtility {
    private static let logger = Logger(subsystem: "com.outspeed.OutspeedSwift", category: "DeviceUtility")
    
    /// Checks if the current device is likely an iPhone 13 or older model using DeviceKit.
    public static func isOlderDeviceModel() -> Bool {
        let currentDevice = Device.current
        
        // Define the array of older iPhone models (up to iPhone 13 series)
        let olderModels: [Device] = [
            // iPhone 13 Series
            .iPhone13, .iPhone13Mini, .iPhone13Pro, .iPhone13ProMax,
            // iPhone SE Series (relevant generations)
            .iPhoneSE2, .iPhoneSE3,
            // iPhone 12 Series
            .iPhone12, .iPhone12Mini, .iPhone12Pro, .iPhone12ProMax,
            // iPhone 11 Series
            .iPhone11, .iPhone11Pro, .iPhone11ProMax,
            // iPhone X Series
            .iPhoneX, .iPhoneXR, .iPhoneXS, .iPhoneXSMax,
            // iPhone 8 Series
            .iPhone8, .iPhone8Plus,
            // iPhone 7 Series
            .iPhone7, .iPhone7Plus,
            // Older SE
            .iPhoneSE,
            // Add older models here if needed
        ]

        if currentDevice.isPhone && olderModels.contains(currentDevice) {
            logger.debug("DeviceKit check: Detected older iPhone model (\(currentDevice.description)). Applying workaround.")
            return true
        }

        // Covers iPhone 14 series and newer, iPads, iPods, Simulators, unknown devices.
        logger.debug("DeviceKit check: Detected newer iPhone model (\(currentDevice.description)) or non-applicable device. No workaround needed.")
        return false
    }
    
    /// Apply speaker override for older devices if needed
    public static func applySpeakerOverrideIfNeeded() {
        guard isOlderDeviceModel() else {
            return
        }
        
        logger.info("Applying speaker override for older device model.")
        // Dispatch after a short delay to ensure session/engine are fully ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                logger.info("Successfully overridden output audio port to speaker.")
            } catch {
                logger.error("Failed to override output audio port to speaker: \(error.localizedDescription)")
            }
        }
    }
} 