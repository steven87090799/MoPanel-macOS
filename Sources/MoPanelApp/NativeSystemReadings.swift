// SMC read packet/protocol and M1 keys adapted from exelban/stats, SMC/smc.swift
// revision 7d3f70dcd6a07177d0a529a1b907021eef740158 (MIT).
// Copyright (c) 2019, 2021 Serhiy Mytrovtsiy. See ThirdParty/Stats-LICENSE.txt.
import Foundation
import Darwin
import IOKit
import SystemConfiguration
import MoPanelCore

struct NativeHardwareReadings: Sendable {
    var pressure: MemoryPressureLevel?
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var gpuUsage: Double?
    var fans: [Double] = []
    var wiredMemory: UInt64?
    var compressedMemory: UInt64?
    var fileCache: UInt64?
}

/// Supplement missing Mole fields using bounded reads on its existing sample cadence.
/// No timer, helper, privileged connection, SMC write, or separate monitoring process.
final class NativeSystemReadings: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.mopanel.native-readings", qos: .utility)
    private let processes = ApplicationUsageReader()
    private(set) var applicationUsage: [ApplicationUsage] = []
    private var smc: ReadOnlySMC?
    private var lastCatalogRead = Date.distantPast
    private var lastRead = Date.distantPast
    var collectedAt: Date { lastRead }
    private var cached = NativeHardwareReadings()
    private(set) var interfaceNames: [String: String] = [:]
    private(set) var primaryInterface: String?

    private func read(apps: [ProcessApplicationIdentity] = []) -> NativeHardwareReadings {
        guard Date().timeIntervalSince(lastRead) >= 5 else { return cached }
        lastRead = Date()
        var value = NativeHardwareReadings()
        var flag: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &flag, &size, nil, 0) == 0,
           size == MemoryLayout<Int32>.size { value.pressure = MemoryPressureLevel(systemValue: flag) }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        if result == KERN_SUCCESS {
            value.wiredMemory = UInt64(vm.wire_count) * UInt64(vm_page_size)
            value.compressedMemory = UInt64(vm.compressor_page_count) * UInt64(vm_page_size)
            value.fileCache = (UInt64(vm.purgeable_count) + UInt64(vm.external_page_count)) * UInt64(vm_page_size)
        }
        if smc == nil { smc = ReadOnlySMC() }
        value.cpuTemperature = averageTemperature(["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"])
        value.gpuTemperature = averageTemperature(["Tg05", "Tg0D"])
        if let count = smc?.value("FNum"), (0...8).contains(count) {
            value.fans = (0..<Int(count)).compactMap { smc?.value("F\($0)Ac") }.filter { (0...30000).contains($0) }
        }
        value.gpuUsage = gpuUtilization()
        applicationUsage = processes.read(apps: apps)
        readNetworkContext()
        cached = value
        return value
    }

    struct Snapshot: Sendable {
        let hardware: NativeHardwareReadings
        let collectedAt: Date
        let applications: [ApplicationUsage]
        let names: [String: String]
        let primary: String?
    }
    func sample(apps: [ProcessApplicationIdentity]) async -> Snapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                let hardware = self.read(apps: apps)
                continuation.resume(returning: Snapshot(hardware: hardware, collectedAt: self.lastRead, applications: self.applicationUsage, names: self.interfaceNames, primary: self.primaryInterface))
            }
        }
    }
    func close() { queue.async { self.smc = nil; self.processes.reset(); self.lastRead = .distantPast } }

    private func averageTemperature(_ keys: [String]) -> Double? {
        let readings = keys.compactMap { smc?.value($0) }.filter { (1...130).contains($0) }
        return readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    private func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        // Only a single GPU can be supplemented without guessing device identity.
        var devices: [Double] = []
        var count = 0
        while count < 16 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            count += 1
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let number = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber,
               number.doubleValue.isFinite, (0...100).contains(number.doubleValue) { devices.append(number.doubleValue) }
        }
        return count == 1 ? devices.first : nil
    }

    private func readNetworkContext() {
        if Date().timeIntervalSince(lastCatalogRead) >= 60, let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            lastCatalogRead = Date()
            interfaceNames = [:]
            for interface in interfaces {
                if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                   let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? { interfaceNames[name] = label }
            }
        }
        let store = SCDynamicStoreCreate(nil, "MoPanel readings" as CFString, nil, nil)
        let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let ipv6 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        primaryInterface = ipv4?["PrimaryInterface"] as? String ?? ipv6?["PrimaryInterface"] as? String
    }
}

// Read-only protocol layout adapted from exelban/stats SMC/smc.swift (MIT).
// Copyright (c) 2019, 2021 Serhiy Mytrovtsiy. See ThirdParty/Stats-LICENSE.txt.
private struct SMCReadPacket {
    struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct Limits { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
    struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private final class ReadOnlySMC {
    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: SMCReadPacket.KeyInfo] = [:]
    private var missingKeys = Set<UInt32>()

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }

    func value(_ key: String) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        var input = SMCReadPacket(), output = SMCReadPacket()
        input.key = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard !missingKeys.contains(input.key) else { return nil }
        let info: SMCReadPacket.KeyInfo
        if let saved = keyInfo[input.key] { info = saved }
        else {
            input.command = 9 // key metadata read
            guard call(&input, &output) else { return nil }
            guard (1...32).contains(output.info.size) else { missingKeys.insert(input.key); return nil }
            info = output.info
            keyInfo[input.key] = info
        }
        input.info.size = info.size
        input.command = 5 // bytes read; this type exposes no write operation
        guard call(&input, &output) else { return nil }
        let type = String(bytes: [24,16,8,0].map { UInt8((info.type >> $0) & 255) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return SMCReadValue.decode(type: type, bytes: bytes)
    }
    private func call(_ input: inout SMCReadPacket, _ output: inout SMCReadPacket) -> Bool {
        var size = MemoryLayout<SMCReadPacket>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        if result == KERN_SUCCESS, output.result == 0x84 { missingKeys.insert(input.key) }
        return result == KERN_SUCCESS && output.result == 0 && size == MemoryLayout<SMCReadPacket>.stride
    }
}
