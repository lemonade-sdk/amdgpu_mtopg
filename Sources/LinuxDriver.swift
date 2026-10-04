// amdgpu_mtopg — MacLinuxGPU transport: the Linux data paths.
//
// MacLinuxGPU runs the unmodified upstream Linux amdgpu driver, so the
// monitor reads what amdgpu_top reads on Linux, through the dext's observer
// user client (type 1):
//   - SysfsRead (selector 80): a file of the amdgpu device's sysfs
//     directory (/sys/class/drm/card0/device/...), produced by the
//     attribute's own show() (gpu_busy_percent, mem_info_*, pp_dpm_*,
//     hwmon/hwmonN/*, gpu_metrics, ...), or a directory listing.
//   - DrmInfo (selector 81): DRM_IOCTL_AMDGPU_INFO through upstream
//     amdgpu_info_ioctl (READ_MMR_REG for GRBM_STATUS sampling).
// The observer client never claims PCI, joins the session or touches queues.
// Both ABIs are defined in mac_linuxgpu dext/sources/session_state.h.
//
// MIT License — see the repository LICENSE.

import Foundation
import IOKit

enum LinuxABI {
    static let observerClient: UInt32 = 1
    static let selQuery: UInt32 = 21        // cached state only
    static let selRuntimeBuild: UInt32 = 43
    static let selSysfsRead: UInt32 = 80
    static let selDrmInfo: UInt32 = 81
    static let opRead: UInt64 = 0
    static let opList: UInt64 = 1
    static let chunk = 4096
    static let pathMax = 256
    static let tagProbeStatus: UInt64 = 0x4c50524f   // "LPRO"
    // include/uapi/drm/amdgpu_drm.h
    static let infoReadMMRReg: UInt64 = 0x15
    // SOC15 GC register layout (gc_*_offset.h regGRBM_STATUS, base index 0;
    // gc_*_sh_mask.h GRBM_STATUS__GUI_ACTIVE). The segment base is the
    // device's own, from its IP discovery table in sysfs.
    static let grbmStatusOffset: UInt32 = 0x0da4
    static let grbmGuiActive: UInt32 = 1 << 31
}

let kIOReturnNotReadyCode: kern_return_t = kern_return_t(bitPattern: 0xe00002d8)
let kIOReturnNotPermittedCode: kern_return_t = kern_return_t(bitPattern: 0xe00002e2)

// MARK: - gpu_metrics

/// A gpu_metrics blob decoded by its own header (format_revision,
/// content_revision) with the upstream struct layout (GPUMetricsLayout.swift,
/// generated from kgd_pp_interface.h). Fields the SMU does not provide are
/// all-ones (smu_cmn_init_soft_gpu_metrics) and read back nil.
struct GPUMetrics {
    let structureSize: Int
    let formatRevision: UInt8
    let contentRevision: UInt8
    let format: GPUMetricsFormat?
    private let bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count >= 4 else { return nil }
        self.bytes = bytes
        let size = Int(bytes[0]) | Int(bytes[1]) << 8
        let frev = bytes[2], crev = bytes[3]
        structureSize = size
        formatRevision = frev
        contentRevision = crev
        let candidate = GPUMetricsLayout.formats.first {
            $0.formatRevision == frev && $0.contentRevision == crev
        }
        // The blob must be the struct the header names.
        if let c = candidate, size == c.size, bytes.count >= c.size {
            format = c
        } else {
            format = nil
        }
    }

    var versionText: String { "v\(formatRevision).\(contentRevision)" }
    var decoded: Bool { format != nil }

    func has(_ name: String) -> Bool { format?.fields[name] != nil }

    func value(_ name: String, index: Int = 0) -> UInt64? {
        guard let field = format?.fields[name], index >= 0, index < field.count else { return nil }
        let offset = field.offset + index * field.size
        guard offset + field.size <= bytes.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<field.size { v |= UInt64(bytes[offset + i]) << (8 * i) }
        let allOnes: UInt64 = field.size >= 8 ? UInt64.max : (UInt64(1) << (8 * field.size)) - 1
        return v == allOnes ? nil : v
    }

    func double(_ name: String) -> Double? { value(name).map { Double($0) } }
}

// MARK: - One refresh of Linux telemetry

final class LinuxSample {
    var error: String?
    var notReady = false          // the upstream driver is not running in a session
    var unsupported = false       // the dext predates SysfsRead
    var modulesRunning: Bool?
    var probeResult: Int64?
    var compiledBuild: UInt64?

    // Fast tier: GRBM_STATUS samples taken this refresh.
    var grbm: [(atNs: UInt64, active: Bool)] = []
    var grbmStatus: String?       // why sampling is unavailable

    // Slow tier (~1 Hz): text attributes by path, their errnos, gpu_metrics.
    var slowAtNs: UInt64 = 0
    var text: [String: String] = [:]
    var errnos: [String: Int32] = [:]
    var metrics: GPUMetrics?
    var hwmon: String?            // "hwmon/hwmonN"
    var hwmonFiles: Set<String> = []

    // The dext's published identity and monitors (IORegistry properties).
    var registry: LinuxRegistryInfo?
}

private extension Array where Element == UInt8 {
    var trimmedText: String {
        String(decoding: self, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Transport

/// One persistent observer connection per MacLinuxGPU service. The observer
/// runs on its own dext queue, so the reads neither wait behind nor delay
/// a session's ioctls; holding the connection avoids recreating a user
/// client and its queue ten times a second.
final class LinuxTransport {
    private final class Connection {
        let port: io_connect_t
        var hwmon: String?
        var hwmonFiles: Set<String> = []
        var grbmOffset: UInt32?
        var grbmUnavailable: String?
        var discovered = false
        var build: UInt64?
        var last = LinuxSample()
        var lastSlowNs: UInt64 = 0
        init(port: io_connect_t) { self.port = port }
    }

    enum ReadError: Error {
        case linux(Int32)          // the attribute's (or walk's) Linux errno
        case notReady
        case unsupported
        case transport(kern_return_t)
    }

    private var connections: [UInt64: Connection] = [:]
    static let slowPeriodNs: UInt64 = 1_000_000_000
    static let grbmSamplesPerRefresh = 5
    static let grbmSpacingUs: UInt32 = 8_000
    let grbmEnabled = ProcessInfo.processInfo.environment["MTOPG_NO_GRBM"] != "1"

    func closeAll() {
        for (_, c) in connections { IOServiceClose(c.port) }
        connections.removeAll()
    }

    func forget(except live: Set<UInt64>) {
        for (id, c) in connections where !live.contains(id) {
            IOServiceClose(c.port)
            connections.removeValue(forKey: id)
        }
    }

    // MARK: calls

    private func call(_ c: Connection, _ selector: UInt32, _ scalars: [UInt64], _ input: [UInt8]?,
                      outputWords: Int, outputBytes: Int) -> (kern_return_t, [UInt64], [UInt8]) {
        var outWords = [UInt64](repeating: 0, count: max(outputWords, 1))
        var outCount = UInt32(outputWords)
        var outBytes = [UInt8](repeating: 0, count: max(outputBytes, 1))
        var outSize = outputBytes
        let kr: kern_return_t = scalars.withUnsafeBufferPointer { scalarsPtr in
            outWords.withUnsafeMutableBufferPointer { wordsPtr in
                outBytes.withUnsafeMutableBufferPointer { bytesPtr in
                    if let input {
                        return input.withUnsafeBufferPointer { inputPtr in
                            IOConnectCallMethod(c.port, selector, scalarsPtr.baseAddress, UInt32(scalars.count),
                                                inputPtr.baseAddress, input.count,
                                                wordsPtr.baseAddress, &outCount,
                                                outputBytes > 0 ? bytesPtr.baseAddress : nil, &outSize)
                        }
                    }
                    return IOConnectCallMethod(c.port, selector, scalarsPtr.baseAddress, UInt32(scalars.count),
                                               nil, 0, wordsPtr.baseAddress, &outCount,
                                               outputBytes > 0 ? bytesPtr.baseAddress : nil, &outSize)
                }
            }
        }
        let words = Array(outWords.prefix(Int(min(outCount, UInt32(outWords.count)))))
        let bytes = Array(outBytes.prefix(min(outSize, outBytes.count)))
        return (kr, words, bytes)
    }

    private static func linuxErrno(_ word: UInt64) -> Int32? {
        let status = Int64(bitPattern: word)
        guard status != 0 else { return nil }
        return status < 0 && status > -4096 ? Int32(-status) : Int32(EIO)
    }

    /// The whole file (or listing), read in chunks up to its full length.
    private func sysfs(_ c: Connection, _ path: String, op: UInt64 = LinuxABI.opRead) -> Result<[UInt8], ReadError> {
        let name = Array(path.utf8)
        guard !name.isEmpty, name.count <= LinuxABI.pathMax else { return .failure(.linux(ENAMETOOLONG)) }
        var data: [UInt8] = []
        for _ in 0..<64 {
            let (kr, words, chunk) = call(c, LinuxABI.selSysfsRead, [op, UInt64(data.count)], name,
                                          outputWords: 3, outputBytes: LinuxABI.chunk)
            if kr == kIOReturnNotReadyCode { return .failure(.notReady) }
            if kr == kIOReturnNotPermittedCode { return .failure(.unsupported) }
            guard kr == KERN_SUCCESS, words.count == 3 else { return .failure(.transport(kr)) }
            if let e = Self.linuxErrno(words[0]) { return .failure(.linux(e)) }
            guard words[1] == UInt64(chunk.count), chunk.count <= LinuxABI.chunk else {
                return .failure(.transport(kIOReturnBadArgument))
            }
            data.append(contentsOf: chunk)
            let length = Int(min(words[2], UInt64(Int.max)))
            if chunk.isEmpty || data.count >= length {
                return .success(length > 0 && data.count > length ? Array(data.prefix(length)) : data)
            }
        }
        return .success(data)
    }

    private func list(_ c: Connection, _ path: String) -> Result<[(kind: Character, name: String)], ReadError> {
        sysfs(c, path, op: LinuxABI.opList).map { bytes in
            String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
                guard line.count > 2, let kind = line.first, line.dropFirst().first == " " else { return nil }
                return (kind, String(line.dropFirst(2)))
            }
        }
    }

    private func drmInfo(_ c: Connection, query: UInt64, args: [UInt8], size: Int) -> Result<[UInt8], ReadError> {
        let (kr, words, bytes) = call(c, LinuxABI.selDrmInfo, [query, UInt64(size)], args.isEmpty ? nil : args,
                                      outputWords: 1, outputBytes: size)
        if kr == kIOReturnNotReadyCode { return .failure(.notReady) }
        if kr == kIOReturnNotPermittedCode { return .failure(.unsupported) }
        guard kr == KERN_SUCCESS, words.count == 1 else { return .failure(.transport(kr)) }
        if let e = Self.linuxErrno(words[0]) { return .failure(.linux(e)) }
        guard bytes.count == size else { return .failure(.transport(kIOReturnBadArgument)) }
        return .success(bytes)
    }

    // MARK: refresh

    func read(_ service: io_service_t, registry: UInt64) -> LinuxSample {
        let c: Connection
        if let existing = connections[registry] {
            c = existing
        } else {
            var port: io_connect_t = IO_OBJECT_NULL
            let kr = IOServiceOpen(service, mach_task_self_, LinuxABI.observerClient, &port)
            guard kr == KERN_SUCCESS else {
                let s = LinuxSample()
                s.error = String(format: "observer open: 0x%08x", kr)
                return s
            }
            c = Connection(port: port)
            connections[registry] = c
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let sample = LinuxSample()
        // Carry the latest slow-tier values; refresh them about once a second.
        let previous = c.last
        sample.modulesRunning = previous.modulesRunning
        sample.probeResult = previous.probeResult
        sample.compiledBuild = previous.compiledBuild
        sample.slowAtNs = previous.slowAtNs
        sample.text = previous.text
        sample.errnos = previous.errnos
        sample.metrics = previous.metrics
        sample.notReady = previous.notReady
        sample.unsupported = previous.unsupported

        if c.lastSlowNs == 0 || now < c.lastSlowNs || now - c.lastSlowNs >= Self.slowPeriodNs {
            c.lastSlowNs = now
            if !readSlow(c, into: sample, at: now) {
                IOServiceClose(c.port)
                connections.removeValue(forKey: registry)
                return sample
            }
        }
        sample.hwmon = c.hwmon
        sample.hwmonFiles = c.hwmonFiles
        if !sample.notReady && !sample.unsupported { readGRBM(c, into: sample) }
        c.last = sample
        return sample
    }

    private static func lost(_ kr: kern_return_t) -> Bool {
        kr == kIOReturnNotAttached || kr == kern_return_t(MACH_SEND_INVALID_DEST) || kr == kIOReturnNoDevice
    }

    /// Cached session state. The dext answers these selectors on its session
    /// queue, behind any in-flight ioctl, so the monitor asks only to explain
    /// a "not ready" and once for the build. False: the connection is dead.
    private func sessionState(_ c: Connection, into s: LinuxSample, probe wanted: Bool) -> Bool {
        if c.build == nil {
            var build = [UInt64](repeating: 0, count: 4)
            var count = UInt32(4)
            let kr = IOConnectCallScalarMethod(c.port, LinuxABI.selRuntimeBuild, nil, 0, &build, &count)
            if Self.lost(kr) { s.error = String(format: "observer connection lost: 0x%08x", kr); return false }
            if kr == KERN_SUCCESS, count == 4 { c.build = build[3] }
        }
        s.compiledBuild = c.build
        guard wanted else { return true }
        var probe = [UInt64](repeating: 0, count: 5)
        var count = UInt32(5)
        var tag = LinuxABI.tagProbeStatus
        let kr = IOConnectCallScalarMethod(c.port, LinuxABI.selQuery, &tag, 1, &probe, &count)
        if Self.lost(kr) { s.error = String(format: "observer connection lost: 0x%08x", kr); return false }
        if kr == KERN_SUCCESS, count == 5 {
            s.modulesRunning = probe[1] != 0
            s.probeResult = Int64(bitPattern: probe[2])
        }
        return true
    }

    /// The ~1 Hz attributes. Returns false when the connection is dead.
    private func readSlow(_ c: Connection, into s: LinuxSample, at now: UInt64) -> Bool {
        guard sessionState(c, into: s, probe: false) else { return false }
        s.slowAtNs = now
        s.notReady = false
        s.unsupported = false
        s.text = [:]
        s.errnos = [:]
        s.metrics = nil
        if !c.discovered {
            switch discover(c) {
            case .failure(.notReady):
                s.notReady = true
                return sessionState(c, into: s, probe: true)
            case .failure(.unsupported):
                s.unsupported = true
                return true
            case .failure(.transport(let kr)) where Self.lost(kr):
                s.error = String(format: "observer connection lost: 0x%08x", kr)
                return false
            default:
                break
            }
        }
        var paths = LinuxPaths.device
        if let h = c.hwmon {
            paths += LinuxPaths.hwmon.filter { c.hwmonFiles.contains($0) }.map { "\(h)/\($0)" }
        }
        for path in paths {
            switch sysfs(c, path) {
            case .success(let bytes):
                s.text[path] = bytes.trimmedText
            case .failure(.linux(let e)):
                s.errnos[path] = e
            case .failure(.notReady):
                s.notReady = true
                c.discovered = false
                return sessionState(c, into: s, probe: true)
            case .failure(.unsupported):
                s.unsupported = true
                return true
            case .failure(.transport(let kr)):
                if Self.lost(kr) {
                    s.error = String(format: "observer connection lost: 0x%08x", kr)
                    return false
                }
                s.errnos[path] = EIO
            }
        }
        s.modulesRunning = true
        s.probeResult = nil
        if case .success(let bytes) = sysfs(c, "gpu_metrics") {
            s.metrics = GPUMetrics(bytes: bytes)
        }
        return true
    }

    /// Per session: the hwmon directory (as Linux tools scan device/hwmon/),
    /// its files, and the GC register segment base for GRBM_STATUS.
    private func discover(_ c: Connection) -> Result<Void, ReadError> {
        c.hwmon = nil
        c.hwmonFiles = []
        c.grbmOffset = nil
        c.grbmUnavailable = nil
        switch list(c, "hwmon") {
        case .success(let entries):
            if let dir = entries.first(where: { $0.kind == "d" && $0.name.hasPrefix("hwmon") }) {
                c.hwmon = "hwmon/\(dir.name)"
                if case .success(let files) = list(c, "hwmon/\(dir.name)") {
                    c.hwmonFiles = Set(files.filter { $0.kind == "f" }.map(\.name))
                }
            }
        case .failure(.notReady): return .failure(.notReady)
        case .failure(.unsupported): return .failure(.unsupported)
        case .failure: break
        }
        switch sysfs(c, "ip_discovery/die/0/GC/0/base_addr") {
        case .success(let bytes):
            let first = bytes.trimmedText.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if first.hasPrefix("0x"), let base = UInt32(first.dropFirst(2), radix: 16) {
                c.grbmOffset = base + LinuxABI.grbmStatusOffset
            } else {
                c.grbmUnavailable = "ip_discovery GC base_addr unreadable"
            }
        case .failure(.linux(let e)):
            c.grbmUnavailable = "ip_discovery GC base_addr: \(String(cString: strerror(e)))"
        case .failure(let e):
            c.grbmUnavailable = "ip_discovery GC base_addr: \(e)"
        }
        c.discovered = true
        return .success(())
    }

    /// amdgpu_top's GRBM sampling: GRBM_STATUS through AMDGPU_INFO_READ_MMR_REG
    /// (upstream checks the offset against the ASIC's allowed list).
    private func readGRBM(_ c: Connection, into s: LinuxSample) {
        guard grbmEnabled else { s.grbmStatus = "GRBM sampling disabled (MTOPG_NO_GRBM=1)"; return }
        guard let offset = c.grbmOffset else { s.grbmStatus = c.grbmUnavailable ?? "GC register base unknown"; return }
        var args = [UInt8]()
        for word in [offset, 1, 0xffff_ffff, 0] {
            withUnsafeBytes(of: word.littleEndian) { args.append(contentsOf: $0) }
        }
        for i in 0..<Self.grbmSamplesPerRefresh {
            if i > 0 { usleep(Self.grbmSpacingUs) }
            switch drmInfo(c, query: LinuxABI.infoReadMMRReg, args: args, size: 4) {
            case .success(let bytes):
                let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                s.grbm.append((clock_gettime_nsec_np(CLOCK_UPTIME_RAW), value & LinuxABI.grbmGuiActive != 0))
            case .failure(.linux(let e)):
                // EFAULT: upstream refused the register for this ASIC.
                c.grbmOffset = nil
                c.grbmUnavailable = "AMDGPU_INFO_READ_MMR_REG GRBM_STATUS: \(String(cString: strerror(e)))"
                s.grbmStatus = c.grbmUnavailable
                return
            case .failure(.unsupported):
                c.grbmOffset = nil
                c.grbmUnavailable = "driver has no DrmInfo selector"
                s.grbmStatus = c.grbmUnavailable
                return
            case .failure(let e):
                s.grbmStatus = "GRBM_STATUS read failed: \(e)"
                return
            }
        }
    }
}

/// The sysfs files the monitor reads, as amdgpu_top reads them on Linux.
enum LinuxPaths {
    static let device = [
        "gpu_busy_percent", "mem_busy_percent",
        "mem_info_vram_used", "mem_info_vram_total",
        "mem_info_vis_vram_used", "mem_info_vis_vram_total",
        "mem_info_gtt_used", "mem_info_gtt_total",
        "pp_dpm_sclk", "pp_dpm_mclk", "pp_dpm_fclk", "pp_dpm_socclk", "pp_dpm_pcie",
        "power_dpm_force_performance_level",
        "current_link_speed", "current_link_width", "max_link_speed", "max_link_width",
        "vendor", "device", "revision",
    ]
    static let hwmon = [
        "name",
        "temp1_input", "temp1_label", "temp2_input", "temp2_label", "temp3_input", "temp3_label",
        "power1_average", "power1_input", "power1_cap", "power1_cap_max",
        "fan1_input", "fan1_max",
        "in0_input", "in0_label", "in1_input", "in1_label",
        "freq1_input", "freq1_label", "freq2_input", "freq2_label",
    ]
}
