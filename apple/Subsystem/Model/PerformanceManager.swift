// Mac Android Subsystem - applies the performance mode while Android runs.
//
// Levers, all adjustable live without restarting Android:
//   CPU      Android takes processor cores online/offline (CPU hotplug through
//            `su`, only on the project's userdebug image: jqssun's user builds have
//            no su, so their cores all stay online), and QEMU runs as a macOS
//            background task in Saver (efficiency cores, throttled I/O).
//   Memory   the virtio balloon (QMP "balloon") returns memory to macOS.
//   Android  its battery saver (`cmd power set-mode`) and fixed-performance mode.
//   Windows  frame rate and bitrate, read by app windows from status.json.
//
// Sound playing or recording in Android lifts Saver to Balanced: background priority
// starves QEMU's audio (Core Audio skips cycles). With the microphone on, Saver never
// uses background priority: a recording that starts starved puts Android's input
// stream into an error state it doesn't recover from.
//
// Smart mode re-evaluates whenever the front app, power source, Low Power Mode or
// thermal state changes, and every 10 seconds.
//
// Licensed under the GNU General Public License v3 or later.

import AppKit
import Foundation
import IOKit.ps

@MainActor
final class PerformanceManager {
    static let shared = PerformanceManager()

    private(set) var level: PerformanceLevel = .balanced
    /// Called when the level changes (the Subsystem republishes its status).
    var onChange: ((PerformanceLevel) -> Void)?

    private var appliedLevel: PerformanceLevel?
    private var appliedPID: pid_t = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private let work = DispatchQueue(label: "msa.performance", qos: .utility)
    private let root = RootShell()
    /// Android has an audio stream out of standby (playing or recording); refreshed by evaluate().
    private var audioActive = false

    private init() {}

    // MARK: Life cycle

    /// Android is running: watch conditions and apply the current level.
    func start() {
        appliedLevel = nil
        let root = root
        work.async { root.available = nil }      // a new boot, maybe a different image
        observeOnce()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in PerformanceManager.shared.evaluate() }
        }
        evaluate(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        appliedLevel = nil
        appliedPID = 0
        audioActive = false
    }

    private func observeOnce() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let reevaluate: (Notification) -> Void = { _ in
            Task { @MainActor in PerformanceManager.shared.evaluate() }
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: reevaluate))
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: reevaluate))
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: reevaluate))
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: reevaluate))

        // Plugging in or unplugging the charger.
        let callback: IOPowerSourceCallbackType = { _ in
            Task { @MainActor in PerformanceManager.shared.evaluate() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    // MARK: Deciding

    struct Conditions {
        var onBattery = false
        var batteryLow = false
        var lowPowerMode = false
        var hot = false
        /// macOS reports memory pressure (warning or critical).
        var memoryPressure = false
        /// Other Mac apps are keeping the processor busy (not counting Android).
        var othersBusy = false
        var windowsOpen = false
        var androidInFront = false
        var gameInFront = false
        var audioActive = false

        /// The Mac needs its resources back, whatever Android is doing.
        var constrained: Bool { lowPowerMode || hot || batteryLow || memoryPressure || othersBusy }
    }

    private let load = SystemLoad()

    func currentConditions() -> Conditions {
        var c = Conditions()
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            c.onBattery = providing == kIOPSBatteryPowerValue
            if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for source in list {
                    guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                          let current = description[kIOPSCurrentCapacityKey] as? Int,
                          let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                    c.batteryLow = c.onBattery && current * 100 / maximum < 20
                }
            }
        }
        c.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        c.hot = thermal == .serious || thermal == .critical
        c.memoryPressure = SystemLoad.memoryPressureLevel >= 2
        c.othersBusy = load.othersBusy(excluding: Subsystem.shared.vmProcessIdentifier)
        c.windowsOpen = Subsystem.shared.appWindowsOpen
        c.audioActive = audioActive

        let prefix = AppConfig.launcherBundlePrefix + "."
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier?.hasPrefix(prefix) == true {
            c.androidInFront = true
            if let bundle = front.bundleURL,
               let package = Bundle(url: bundle)?.object(forInfoDictionaryKey: "MSAPackageName") as? String {
                c.gameInFront = Subsystem.shared.apps.first { $0.package == package }?.isGame == true
            }
        }
        return c
    }

    func resolve(_ mode: PerformanceMode, _ c: Conditions) -> PerformanceLevel {
        let level = baseLevel(mode, c)
        return level == .saver && c.audioActive ? .balanced : level
    }

    private func baseLevel(_ mode: PerformanceMode, _ c: Conditions) -> PerformanceLevel {
        switch mode {
        case .standard: return .standard
        case .performance: return .performance
        case .powerSaver:
            // Android only runs while an app is open (Subsystem.idleShutdownDelay); while it
            // does, it gets a little more room for the app in front when the Mac can spare it.
            if c.constrained || c.onBattery { return .saver }
            return c.androidInFront ? .balanced : .saver
        case .smart:
            // The Mac needs its resources, but the Android app in front stays usable:
            // Saver's background priority starves it (frames of seconds, ANRs).
            if c.constrained { return c.androidInFront ? .balanced : .saver }
            if !c.windowsOpen { return .saver }                  // ready, idling in the background
            if c.gameInFront { return .performance }
            if c.androidInFront { return c.onBattery ? .balanced : .performance }
            return c.onBattery ? .saver : .balanced              // windows open, another Mac app in front
        }
    }

    func evaluate(force: Bool = false) {
        let subsystem = Subsystem.shared
        guard case .running = subsystem.state else { return }
        let newLevel = resolve(SubsystemSettings.shared.performanceMode, currentConditions())
        let pid = subsystem.vmProcessIdentifier ?? 0
        refreshAudioActivity(subsystem.adbConnection)
        let changed = newLevel != level
        level = newLevel
        if changed { onChange?(newLevel) }
        guard force || newLevel != appliedLevel || pid != appliedPID else { return }
        appliedLevel = newLevel
        appliedPID = pid
        let background = newLevel.backgroundPriority && subsystem.launchedWith?.microphone != true
        apply(newLevel, background: background, pid: pid, adb: subsystem.adbConnection,
              cpuCount: SubsystemSettings.shared.cpuCount, memoryMB: SubsystemSettings.shared.memoryMB)
    }

    /// Ask Android whether any audio stream is out of standby (AudioFlinger puts one in
    /// standby 3 s after its last track stops) and re-evaluate when that changes.
    private func refreshAudioActivity(_ adb: ADBConnection?) {
        guard let adb, [.smart, .powerSaver].contains(SubsystemSettings.shared.performanceMode) else { return }
        work.async {
            guard let count = try? adb.execString("dumpsys media.audio_flinger | grep -c 'Standby: no'", timeout: 5) else { return }
            let active = (Int(count) ?? 0) > 0
            Task { @MainActor in
                let manager = PerformanceManager.shared
                guard active != manager.audioActive else { return }
                manager.audioActive = active
                manager.evaluate()
            }
        }
    }

    // MARK: Applying

    private func apply(_ level: PerformanceLevel, background: Bool, pid: pid_t, adb: ADBConnection?, cpuCount: Int, memoryMB: Int) {
        let root = root
        work.async {
            // 1. QEMU's scheduling class: background (efficiency cores) or normal.
            if pid > 0 {
                let PRIO_DARWIN_PROCESS: Int32 = 4
                let PRIO_DARWIN_BG: Int32 = 0x1000
                setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0)
            }

            // 2. Memory: balloon down to the level's share (never below 1.5 GB).
            let targetMB = max(1536, Int(Double(memoryMB) * level.memoryShare))
            QMPClient.execute("balloon", arguments: ["value": min(targetMB, memoryMB) * 1_048_576])

            guard let adb else { return }
            // 3. Processor cores online inside Android (cpu0 always stays on). Needs root:
            //    adbd runs as shell (uid 2000), which can't write cpuN/online.
            if cpuCount > 1, root.check(adb) {
                let online = max(level == .saver ? min(2, cpuCount) : 1, Int((Double(cpuCount) * level.cpuShare).rounded()))
                let script = (1..<cpuCount).map { "echo \($0 < online ? 1 : 0) > /sys/devices/system/cpu/cpu\($0)/online" }
                    .joined(separator: "; ")
                _ = try? adb.exec("su 0 sh -c '\(script)'", timeout: 10)
            }

            // 4. Android's own power settings.
            _ = try? adb.exec("cmd power set-mode \(level.androidBatterySaver ? 1 : 0)", timeout: 10)
            _ = try? adb.exec("cmd power set-fixed-performance-mode-enabled \(level.androidFixedPerformance)", timeout: 10)
        }
    }
}

/// Whether `su 0` works inside Android: yes on the project's userdebug image, no on
/// jqssun's user builds. Asked once per boot; only used on PerformanceManager's queue.
private final class RootShell: @unchecked Sendable {
    var available: Bool?

    func check(_ adb: ADBConnection) -> Bool {
        if let available { return available }
        // Throws while ADB isn't ready yet; ask again next time.
        guard let uid = try? adb.execString("su 0 id -u", timeout: 10) else { return false }
        let found = uid == "0"
        available = found
        if !found { NSLog("Performance: Android has no su, so its processor cores all stay online") }
        return found
    }
}

/// How busy the Mac is apart from Android: overall CPU use minus QEMU's own,
/// sampled between evaluations, plus the kernel's memory-pressure level.
final class SystemLoad {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastQEMU: (cpu: UInt64, wall: UInt64)?
    private var busyStreak = 0
    private var lastSample = Date.distantPast
    private var cachedBusy = false

    /// True when other apps have used more than 70% of the processor for two samples
    /// in a row. Samples at most every 5 seconds, however often it's asked.
    func othersBusy(excluding qemu: pid_t?) -> Bool {
        guard Date().timeIntervalSince(lastSample) >= 5 else { return cachedBusy }
        lastSample = Date()
        cachedBusy = sample(excluding: qemu)
        return cachedBusy
    }

    private func sample(excluding qemu: pid_t?) -> Bool {
        guard let ticks = Self.cpuTicks() else { return false }
        defer { lastTicks = ticks }
        guard let previous = lastTicks, ticks.total > previous.total, ticks.busy >= previous.busy else { return false }
        let hostBusy = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)

        var qemuShare = 0.0
        if let qemu, let sample = Self.processCPU(qemu) {
            if let last = lastQEMU, sample.wall > last.wall, sample.cpu >= last.cpu {
                let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
                qemuShare = Double(sample.cpu - last.cpu) / Double(sample.wall - last.wall) / cores
            }
            lastQEMU = sample
        }
        busyStreak = hostBusy - qemuShare > 0.7 ? busyStreak + 1 : 0
        return busyStreak >= 2
    }

    /// 1 normal, 2 warning, 4 critical.
    static var memoryPressureLevel: Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : 0
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// QEMU's CPU time and the wall clock, both in nanoseconds.
    private static func processCPU(_ pid: pid_t) -> (cpu: UInt64, wall: UInt64)? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = usage.ri_user_time + usage.ri_system_time
        let cpu = ticks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
        return (cpu, DispatchTime.now().uptimeNanoseconds)
    }
}
