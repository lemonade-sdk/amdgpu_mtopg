// amdgpu_mtopg — MacLinuxGPU sample model.
//
// The panels follow amdgpu_top on Linux, and every value names its source:
//  - GPU load: the fraction of GRBM_STATUS samples with GUI_ACTIVE set over
//    a rolling 2 s window (AMDGPU_INFO_READ_MMR_REG), else gpu_busy_percent
//    (the SMU's average GFX activity).
//  - Memory activity: mem_busy_percent, with gpu_metrics
//    average_umc_activity beside it.
//  - VRAM/GTT: mem_info_* (the TTM managers' usage).
//  - Clocks: gpu_metrics current/average clocks and the pp_dpm_* levels.
//  - Sensors: hwmon (temperatures with their labels, power, fan, voltage).
//  - Throttle status and the PCIe link.
//
// MIT License — see the repository LICENSE.

import Foundation

struct DPMLevel: Identifiable {
    let id: Int
    let label: String      // "0", "1", "S" (deep sleep) ...
    let text: String       // the level as upstream prints it
    let mhz: Double?
    let active: Bool
}

struct LinuxClockRow: Identifiable {
    let id: Int
    let name: String
    let current: Double?       // gpu_metrics current_*
    let average: Double?       // gpu_metrics average_*_frequency
    let levels: [DPMLevel]     // pp_dpm_*
    let levelsError: String?
}

struct LinuxSensorRow: Identifiable {
    let id: Int
    let label: String
    let value: Double?
    let maxValue: Double?
    let text: String
    let source: String
}

/// One output of the GPU and the monitor on it, as the dext publishes it
/// (MacLinuxGPUDisplays): DRM connector state from upstream DC, the monitor
/// name from its EDID.
struct LinuxDisplayRow: Identifiable {
    let id: Int
    let connector: String          // "DP-4"
    let connected: Bool
    let monitor: String?           // "DELL UP2716D"
    let mode: String?              // what the GPU scans out, or the monitor's preferred mode
    let driven: Bool               // the GPU is scanning out to it
}

/// What the dext publishes on its IOService beside System Information's
/// keys (mac_linuxgpu dext/sources/device_identity.h): MacLinuxGPUDevice and
/// MacLinuxGPUDisplays. Read from the IORegistry, no observer call; nil
/// fields are values the driver did not publish.
struct LinuxRegistryInfo {
    var name: String?
    var vendorID: Int?
    var deviceID: Int?
    var revisionID: Int?
    var vramBytes: UInt64?
    var vramType: String?
    var gfxTarget: String?
    var vbios: String?
    var displays: [LinuxDisplayRow]?   // nil: not published (no display client, or DC off)

    init?(device: [String: Any]?, displays: [String: Any]?) {
        guard let device else { return nil }
        func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func text(_ d: [String: Any], _ k: String) -> String? {
            (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        name = text(device, "Name")
        vendorID = int(device, "VendorID")
        deviceID = int(device, "DeviceID")
        revisionID = int(device, "RevisionID")
        vramBytes = (device["VRAMBytes"] as? NSNumber)?.uint64Value
        vramType = text(device, "VRAMType")
        gfxTarget = text(device, "GFXTarget")
        vbios = text(device, "VBIOSPartNumber")
        if let displays {
            let list = displays["Connectors"] as? [[String: Any]] ?? []
            self.displays = list.enumerated().compactMap { i, c in
                guard let connector = text(c, "Name") else { return nil }
                let driven = (c["Lit"] as? Bool) ?? false
                var mode: String?
                let (w, h, r) = driven ? ("LitWidth", "LitHeight", "LitRefresh")
                                       : ("PreferredWidth", "PreferredHeight", "PreferredRefresh")
                if let width = int(c, w), let height = int(c, h) {
                    mode = "\(width)x\(height)" + (int(c, r).map { $0 > 0 ? "@\($0)" : "" } ?? "")
                }
                return LinuxDisplayRow(id: i, connector: connector,
                                       connected: text(c, "Status") == "connected",
                                       monitor: text(c, "Monitor"), mode: mode, driven: driven)
            }
        }
    }

    /// "AMD Radeon AI Pro R9700 · 32 GiB GDDR6 · gfx1201"
    var headline: String? {
        var parts: [String] = []
        if let name { parts.append(name) }
        if let vramBytes, vramBytes > 0 {
            let gib = Double(vramBytes) / 1_073_741_824.0
            parts.append((gib == gib.rounded() ? "\(Int(gib)) GiB" : String(format: "%.1f GiB", gib)) +
                         (vramType.map { " \($0)" } ?? ""))
        }
        if let gfxTarget { parts.append(gfxTarget) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct LinuxSnapshot {
    var status: String = ""
    var statusOK = false
    var deviceLine: String = ""
    var deviceName: String?            // the dext's published identity headline
    var displays: [LinuxDisplayRow]?   // the monitors on the GPU's outputs
    var linkLine: String = ""
    var perfLevel: String?
    var metricsFormat: String = "gpu_metrics: not read"
    var build: UInt64?

    var core: [(age: Double, value: Double?)] = []
    var coreCurrent: Double?
    var coreHardware = false
    var coreSummary = ""
    var coreDetail = ""

    var memory: [(age: Double, value: Double?)] = []
    var memoryCurrent: Double?
    var memorySummary = ""
    var memoryDetail = ""
    var umcMetrics: Double?

    var vram: (used: Double, total: Double)?
    var visibleVram: (used: Double, total: Double)?
    var gtt: (used: Double, total: Double)?
    var memoryError: String?

    var clocks: [LinuxClockRow] = []
    var sensors: [LinuxSensorRow] = []
    var throttleRaw: UInt64?
    var throttleIndependent: UInt64?
    var throttleActive: [String] = []
    var pcie: [(label: String, text: String)] = []
    var pcieLevels: [DPMLevel] = []
}

final class LinuxHistory {
    struct Point { var timeNs: UInt64; var core: Double?; var memory: Double? }
    private(set) var points: [Point] = []
    private var grbm: [(atNs: UInt64, active: Bool)] = []
    private let grbmWindowNs: UInt64 = 2_000_000_000
    private(set) var coreFromGRBM = false

    func reset() {
        points.removeAll()
        grbm.removeAll()
        coreFromGRBM = false
    }

    func add(_ s: LinuxSample, nowNs now: UInt64) {
        if s.notReady || s.unsupported || s.error != nil {
            reset()
            return
        }
        for sample in s.grbm where grbm.last.map({ $0.atNs < sample.atNs }) ?? true {
            grbm.append(sample)
        }
        grbm.removeAll { now < $0.atNs || now - $0.atNs > grbmWindowNs }
        var core: Double?
        coreFromGRBM = false
        if grbm.count >= 8 {
            core = Double(grbm.filter(\.active).count) / Double(grbm.count) * 100
            coreFromGRBM = true
        } else if let busy = s.text["gpu_busy_percent"].flatMap(Double.init), busy <= 100 {
            core = busy
        }
        let memory = s.text["mem_busy_percent"].flatMap(Double.init).flatMap { $0 <= 100 ? $0 : nil }
        points.append(Point(timeNs: now, core: core, memory: memory))
        while let first = points.first, now > first.timeNs, now - first.timeNs >= SampleHistory.windowNs {
            points.removeFirst()
        }
        if points.count > SampleHistory.maxPoints { points.removeFirst(points.count - SampleHistory.maxPoints) }
    }

    func series(_ key: KeyPath<Point, Double?>, nowNs: UInt64) -> [(age: Double, value: Double?)] {
        points.map { (age: Double(nowNs - min($0.timeNs, nowNs)) / 1e9, value: $0[keyPath: key]) }
    }
}

// SMU_THROTTLER_*_BIT (drivers/gpu/drm/amd/pm/swsmu/inc/amdgpu_smu.h): the
// ASIC-independent bits of gpu_metrics indep_throttle_status.
let kIndependentThrottlers: [(bit: Int, name: String)] = [
    (0, "PPT0"), (1, "PPT1"), (2, "PPT2"), (3, "PPT3"), (4, "SPL"), (5, "FPPT"), (6, "SPPT"),
    (7, "SPPT_APU"), (16, "TDC_GFX"), (17, "TDC_SOC"), (18, "TDC_MEM"), (19, "TDC_VDD"),
    (20, "TDC_CVIP"), (21, "EDC_CPU"), (22, "EDC_GFX"), (23, "APCC"), (32, "TEMP_GPU"),
    (33, "TEMP_CORE"), (34, "TEMP_MEM"), (35, "TEMP_EDGE"), (36, "TEMP_HOTSPOT"), (37, "TEMP_SOC"),
    (38, "TEMP_VR_GFX"), (39, "TEMP_VR_SOC"), (40, "TEMP_VR_MEM0"), (41, "TEMP_VR_MEM1"),
    (42, "TEMP_LIQUID0"), (43, "TEMP_LIQUID1"), (44, "VRHOT0"), (45, "VRHOT1"),
    (46, "PROCHOT_CPU"), (47, "PROCHOT_GFX"), (56, "PPM"), (57, "FIT"),
]

/// pp_dpm_* as upstream prints it: "N: <MHz>Mhz [*]" per level, "S:" for
/// deep sleep, "*" on the current level; pp_dpm_pcie lines carry the link.
func parseDPMLevels(_ text: String?) -> [DPMLevel] {
    guard let text else { return [] }
    return text.split(separator: "\n").enumerated().compactMap { index, raw in
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let label = String(line[..<colon])
        var body = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let active = body.hasSuffix("*")
        if active { body = String(body.dropLast()).trimmingCharacters(in: .whitespaces) }
        let mhz = body.split(separator: " ").compactMap { word -> Double? in
            let w = word.lowercased()
            guard w.hasSuffix("mhz") else { return nil }
            return Double(w.dropLast(3))
        }.first
        return DPMLevel(id: index, label: label, text: body, mhz: mhz, active: active)
    }
}

private func errnoText(_ e: Int32) -> String { "\(String(cString: strerror(e))) (errno \(e))" }

func makeLinuxSnapshot(_ s: LinuxSample, history: LinuxHistory, nowNs: UInt64) -> LinuxSnapshot {
    var snap = LinuxSnapshot()
    snap.build = s.compiledBuild
    // The dext's published identity and monitors: known even while no
    // session runs (the name from the PCI IDs, the rest after the probe).
    snap.deviceName = s.registry?.headline
    snap.displays = s.registry?.displays
    if let e = s.error {
        snap.status = e
        return snap
    }
    if s.unsupported {
        snap.status = "this MacLinuxGPU build predates the observer Linux reads (SysfsRead, selector 80)"
        return snap
    }
    if s.notReady || s.modulesRunning == false {
        snap.status = s.modulesRunning == false
            ? "upstream amdgpu not running: no GPU session yet" + (s.probeResult.map { $0 != 0 ? " (last probe \($0))" : "" } ?? "")
            : "upstream amdgpu not running in an open session"
        return snap
    }
    snap.status = "upstream amdgpu running"
    snap.statusOK = true
    let t = s.text
    func percent(_ path: String) -> Double? { t[path].flatMap(Double.init).flatMap { $0 <= 100 ? $0 : nil } }
    func bytes(_ path: String) -> Double? { t[path].flatMap(Double.init) }

    // Identity and link (pci-sysfs: the endpoint's own registers).
    let ids = [t["vendor"], t["device"]].compactMap { $0?.replacingOccurrences(of: "0x", with: "") }
    snap.deviceLine = ids.count == 2 ? "\(ids[0]):\(ids[1])" + (t["revision"].map { " rev \($0)" } ?? "") : ""
    snap.perfLevel = t["power_dpm_force_performance_level"]

    // GPU load.
    snap.core = history.series(\.core, nowNs: nowNs)
    snap.coreCurrent = history.points.last?.core
    snap.coreHardware = history.coreFromGRBM
    if history.coreFromGRBM {
        snap.coreSummary = "GRBM_STATUS.GUI_ACTIVE samples, rolling 2 s; not CU occupancy"
        snap.coreDetail = "Fraction of GRBM_STATUS reads (AMDGPU_INFO_READ_MMR_REG, \(LinuxTransport.grbmSamplesPerRefresh) per 100 ms) with GUI_ACTIVE set, as amdgpu_top samples it: GFX pipeline active time, not shader occupancy. Reading the register disables GFXOFF briefly each time."
    } else {
        snap.coreSummary = "gpu_busy_percent (SMU average GFX activity)"
        snap.coreDetail = "GRBM sampling unavailable: \(s.grbmStatus ?? "no samples yet"). Showing sysfs gpu_busy_percent, the SMU firmware's average GFX activity (AMDGPU_PP_SENSOR_GPU_LOAD), updated about once a second."
    }

    // Memory activity.
    snap.memory = history.series(\.memory, nowNs: nowNs)
    snap.memoryCurrent = history.points.last?.memory
    snap.umcMetrics = s.metrics?.double("average_umc_activity").flatMap { $0 <= 100 ? $0 : nil }
    snap.memorySummary = "mem_busy_percent (SMU memory-controller activity)"
        + (snap.umcMetrics.map { "; gpu_metrics UMC \(fmt($0, 0))%" } ?? "")
    snap.memoryDetail = "sysfs mem_busy_percent (AMDGPU_PP_SENSOR_MEM_LOAD) and gpu_metrics average_umc_activity: firmware averages of memory-controller activity, not bandwidth."
    if let e = s.errnos["mem_busy_percent"] { snap.memorySummary = "mem_busy_percent: \(errnoText(e))" }

    // VRAM / GTT.
    let gib = 1_073_741_824.0
    if let used = bytes("mem_info_vram_used"), let total = bytes("mem_info_vram_total"), total > 0 {
        snap.vram = (used / gib, total / gib)
    }
    if let used = bytes("mem_info_vis_vram_used"), let total = bytes("mem_info_vis_vram_total"), total > 0 {
        snap.visibleVram = (used / gib, total / gib)
    }
    if let used = bytes("mem_info_gtt_used"), let total = bytes("mem_info_gtt_total"), total > 0 {
        snap.gtt = (used / gib, total / gib)
    }
    if snap.vram == nil, let e = s.errnos["mem_info_vram_total"] { snap.memoryError = "mem_info_vram_total: \(errnoText(e))" }

    // Clocks.
    let m = s.metrics
    if let m {
        snap.metricsFormat = m.decoded
            ? "gpu_metrics \(m.versionText), \(m.structureSize) bytes"
            : "gpu_metrics \(m.versionText) (\(m.structureSize) bytes): no discrete-GPU layout for this format"
    } else if let e = s.errnos["gpu_metrics"] {
        snap.metricsFormat = "gpu_metrics: \(errnoText(e))"
    }
    let clockDomains: [(String, String, String, String)] = [
        ("GFX", "current_gfxclk", "average_gfxclk_frequency", "pp_dpm_sclk"),
        ("MEMORY", "current_uclk", "average_uclk_frequency", "pp_dpm_mclk"),
        ("SOC", "current_socclk", "average_socclk_frequency", "pp_dpm_socclk"),
        ("FABRIC", "", "", "pp_dpm_fclk"),
    ]
    for (i, domain) in clockDomains.enumerated() {
        let levels = parseDPMLevels(t[domain.3])
        snap.clocks.append(LinuxClockRow(
            id: i, name: domain.0,
            current: domain.1.isEmpty ? nil : m?.double(domain.1),
            average: domain.2.isEmpty ? nil : m?.double(domain.2),
            levels: levels,
            levelsError: s.errnos[domain.3].map { "\(domain.3): \(errnoText($0))" }))
    }

    // Sensors: hwmon, labeled by the driver's own *_label files.
    var rows: [LinuxSensorRow] = []
    if let h = s.hwmon {
        func hw(_ name: String) -> String? { t["\(h)/\(name)"] }
        for n in 1...3 {
            guard let raw = hw("temp\(n)_input").flatMap(Double.init) else { continue }
            let label = hw("temp\(n)_label") ?? "temp\(n)"
            rows.append(LinuxSensorRow(id: rows.count, label: "Temp \(label)", value: raw / 1000,
                                       maxValue: 110, text: String(format: "%.0f °C", raw / 1000),
                                       source: "\(h)/temp\(n)_input"))
        }
        let cap = hw("power1_cap").flatMap(Double.init).map { $0 / 1e6 }
        for (file, label) in [("power1_average", "Power avg"), ("power1_input", "Power now")] {
            guard let watts = hw(file).flatMap(Double.init).map({ $0 / 1e6 }) else { continue }
            rows.append(LinuxSensorRow(id: rows.count, label: label, value: watts, maxValue: cap ?? 400,
                                       text: String(format: "%.0f W", watts) + (cap.map { String(format: " / %.0f W cap", $0) } ?? ""),
                                       source: "\(h)/\(file) (\(h)/power1_cap)"))
        }
        if let rpm = hw("fan1_input").flatMap(Double.init) {
            let max = hw("fan1_max").flatMap(Double.init)
            rows.append(LinuxSensorRow(id: rows.count, label: "Fan", value: rpm, maxValue: max ?? 5000,
                                       text: String(format: "%.0f RPM", rpm), source: "\(h)/fan1_input"))
        }
        for n in 0...1 {
            guard let mv = hw("in\(n)_input").flatMap(Double.init) else { continue }
            let label = hw("in\(n)_label") ?? "in\(n)"
            rows.append(LinuxSensorRow(id: rows.count, label: "Volt \(label)", value: mv, maxValue: 1500,
                                       text: String(format: "%.0f mV", mv), source: "\(h)/in\(n)_input"))
        }
        for n in 1...2 {
            guard let hz = hw("freq\(n)_input").flatMap(Double.init) else { continue }
            let label = hw("freq\(n)_label") ?? "freq\(n)"
            rows.append(LinuxSensorRow(id: rows.count, label: "Clock \(label)", value: nil, maxValue: nil,
                                       text: String(format: "%.0f MHz", hz / 1e6), source: "\(h)/freq\(n)_input"))
        }
    }
    snap.sensors = rows

    // Throttling (gpu_metrics).
    snap.throttleRaw = m?.value("throttle_status")
    snap.throttleIndependent = m?.value("indep_throttle_status")
    if let bits = snap.throttleIndependent {
        snap.throttleActive = kIndependentThrottlers.filter { bits & (UInt64(1) << UInt64($0.bit)) != 0 }.map(\.name)
    }

    // PCIe link: the endpoint's link status (pci-sysfs) and the SMU's view.
    if let speed = t["current_link_speed"], let width = t["current_link_width"] {
        snap.pcie.append(("endpoint link", "\(speed) x\(width)"))
        snap.linkLine = "PCIe \(speed) x\(width)"
    }
    if let speed = t["max_link_speed"], let width = t["max_link_width"] {
        snap.pcie.append(("endpoint max", "\(speed) x\(width)"))
    }
    if let w = m?.value("pcie_link_width"), let sp = m?.value("pcie_link_speed") {
        snap.pcie.append(("SMU (gpu_metrics)", String(format: "%.1f GT/s x%llu", Double(sp) / 10, w)))
    }
    snap.pcieLevels = parseDPMLevels(t["pp_dpm_pcie"])
    return snap
}
