import Foundation
import IOKit
import IOKit.hid

/// Detects whether a non-Apple keyboard is attached.
///
/// Fn on third-party keyboards is usually handled entirely in the keyboard's
/// own firmware and never reaches macOS as `.maskSecondaryFn`, so Fn-based
/// push-to-talk cannot work. When one is present we auto-select the
/// Ctrl+Opt fallback instead of silently doing nothing.
enum KeyboardWatch {
    private static let appleVendorID = 1452  // 0x05AC

    struct Result {
        let hasExternalNonApple: Bool
        let names: [String]
    }

    static func scan() -> Result {
        guard let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0) as IOHIDManager? else {
            return Result(hasExternalNonApple: false, names: [])
        }
        let match: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return Result(hasExternalNonApple: false, names: [])
        }

        var names: [String] = []
        for device in devices {
            let vendor = property(device, kIOHIDVendorIDKey) as? Int ?? 0
            let name = property(device, kIOHIDProductKey) as? String ?? "Unknown keyboard"
            if vendor != appleVendorID && vendor != 0 {
                names.append(name)
            }
        }
        return Result(hasExternalNonApple: !names.isEmpty, names: names)
    }

    /// The value of System Settings → Keyboard → "Press 🌐 key to".
    /// 0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji, 3 = Start Dictation.
    static func fnUsageType() -> Int {
        UserDefaults(suiteName: "com.apple.HIToolbox")?
            .object(forKey: "AppleFnUsageType") as? Int ?? 0
    }

    static var fnIsFree: Bool { fnUsageType() == 0 }

    private static func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }
}
