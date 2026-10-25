import CoreFoundation
import HeadsUpCore
import IOKit.ps
import IOKit.pwr_mgt

/// Caffeine's power assertions through IOKit (`IOPMAssertionCreateWithName`). It holds
/// exactly the kinds last asked for: a kind no longer wanted is released at once.
@MainActor
final class IOKitPowerAssertions: PowerAssertions {
    private var held: [PowerAssertionKind: IOPMAssertionID] = [:]

    func hold(_ kinds: Set<PowerAssertionKind>) -> Set<PowerAssertionKind> {
        for (kind, id) in held where !kinds.contains(kind) {
            IOPMAssertionRelease(id)
            held[kind] = nil
        }
        for kind in kinds where held[kind] == nil {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                Self.type(kind), IOPMAssertionLevel(kIOPMAssertionLevelOn), "HeadsUp Caffeine" as CFString, &id)
            if result == kIOReturnSuccess {
                held[kind] = id
            }
        }
        return Set(held.keys)
    }

    private static func type(_ kind: PowerAssertionKind) -> CFString {
        switch kind {
        case .displaySleep: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        case .systemSleep: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        }
    }
}

/// Whether the Mac runs on battery, and a callback when that changes
/// (`IOPSNotificationCreateRunLoopSource` on the main run loop).
@MainActor
final class IOKitPowerSource: PowerSource {
    private var changed: (@MainActor () -> Void)?
    private var source: CFRunLoopSource?

    var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    func observe(_ changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        guard source == nil else { return }
        // The power source lives as long as the app, so an unretained pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard
            let created = IOPSNotificationCreateRunLoopSource(
                { context in
                    guard let context else { return }
                    let power = Unmanaged<IOKitPowerSource>.fromOpaque(context).takeUnretainedValue()
                    // The source is added to the main run loop, so this runs on the main thread.
                    MainActor.assumeIsolated { power.changed?() }
                }, context)?.takeRetainedValue()
        else { return }
        source = created
        // Common modes, so a change is seen while a menu or a drag tracks events too (Rev 3).
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }
}
