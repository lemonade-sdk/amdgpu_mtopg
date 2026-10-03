// amdgpu_mtopg — MacLinuxGPU panels (the Linux data paths).
//
// MIT License — see the repository LICENSE.

import SwiftUI

struct LinuxContentView: View {
    let snap: TelemetrySnapshot
    let linux: LinuxSnapshot

    private var caption: Font { .system(size: 9, design: .monospaced) }
    private var body11: Font { .system(size: 11, design: .monospaced) }

    var body: some View {
        VStack(spacing: 10) {
            header
            HStack(alignment: .top, spacing: 10) {
                Panel(title: "GPU Load",
                      right: linux.coreCurrent.map { "[ \(fmt($0, 0))% ]" } ?? "[ n/a ]") {
                    TimeSeriesChart(samples: linux.core, windowSeconds: 60,
                                    color: Palette.accent, fill: Palette.accentFill,
                                    hasData: linux.core.contains { $0.value != nil },
                                    emptyCaption: linux.statusOK ? "No GFX activity sample yet" : linux.status)
                        .frame(height: 150)
                    SourceCaption(summary: linux.statusOK ? linux.coreSummary : "no source",
                                  detail: linux.coreDetail)
                }
                Panel(title: "Memory Activity",
                      right: linux.memoryCurrent.map { "[ \(fmt($0, 0))% ]" } ?? "[ n/a ]") {
                    TimeSeriesChart(samples: linux.memory, windowSeconds: 60,
                                    color: Palette.umc, fill: Palette.umcFill,
                                    hasData: linux.memory.contains { $0.value != nil },
                                    emptyCaption: linux.statusOK ? "No memory activity sample yet" : linux.status)
                        .frame(height: 150)
                    SourceCaption(summary: linux.statusOK ? linux.memorySummary : "no source",
                                  detail: linux.memoryDetail)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                memoryPanel
                clocksPanel
                sensorsPanel
            }
            HStack(alignment: .top, spacing: 10) {
                throttlePanel
                pciePanel
            }
            Spacer(minLength: 0)
            HStack {
                Text("amdgpu_mtopg — read-only observer of MacLinuxGPU (upstream amdgpu sysfs and AMDGPU_INFO); Esc quits")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                Spacer()
                if !snap.deviceLabel.isEmpty {
                    Text("device \(snap.deviceLabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.dim)
                }
            }
        }
        .padding(12)
        .background(Palette.background.ignoresSafeArea())
        .escToQuit()
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("AMD GPU monitor")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.bright)
            Text("MacLinuxGPU")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.accent)
            if !linux.deviceLine.isEmpty {
                Text(linux.deviceLine).font(body11).foregroundStyle(Palette.dim)
            }
            if let b = linux.build, b > 0 {
                Text("runtime ABI \(b)").font(body11).foregroundStyle(Palette.dim)
            }
            Text(linux.status)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(linux.statusOK ? Palette.umc : Palette.warm)
                .lineLimit(1)
            Spacer()
            if let level = linux.perfLevel {
                Text("perf level: \(level)").font(body11).foregroundStyle(Palette.dim)
            }
            if let e = snap.error {
                Text(e).font(body11).foregroundStyle(.red)
            }
        }
    }

    private func meter(_ label: String, _ pair: (used: Double, total: Double)?, color: Color) -> some View {
        Group {
            if let p = pair {
                Meter(label: label, value: p.used, maxValue: p.total,
                      text: String(format: "%.2f / %.2f GiB (%.0f%%)", p.used, p.total, p.used / p.total * 100),
                      color: color)
            } else {
                Meter(label: label, value: nil, maxValue: nil, text: "n/a", color: color)
            }
        }
    }

    private var memoryPanel: some View {
        Panel(title: "VRAM / GTT") {
            meter("VRAM", linux.vram, color: Palette.accent)
            meter("VRAM CPU-visible", linux.visibleVram, color: Palette.accent)
            meter("GTT", linux.gtt, color: Palette.warm)
            if let e = linux.memoryError {
                Text(e).font(caption).foregroundStyle(Palette.warm)
            }
            Text("source: sysfs mem_info_* (TTM VRAM/GTT manager usage)")
                .font(caption).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var clocksPanel: some View {
        Panel(title: "Clocks (MHz)") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(linux.clocks) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(row.name).frame(width: 64, alignment: .leading)
                            Text(row.current.map { "cur \(fmtInt($0))" } ?? "cur n/a")
                                .frame(width: 80, alignment: .trailing)
                            Text(row.average.map { "avg \(fmtInt($0))" } ?? "avg n/a")
                                .frame(width: 80, alignment: .trailing)
                            Spacer()
                        }
                        .font(body11)
                        .foregroundStyle(row.current != nil || row.average != nil ? Palette.bright : Palette.dim)
                        if !row.levels.isEmpty {
                            Text("DPM " + row.levels.map { ($0.active ? "[" : "") + ($0.mhz.map { fmtInt($0) } ?? $0.text) + ($0.active ? "]" : "") }.joined(separator: " "))
                                .font(caption).foregroundStyle(Palette.dim)
                                .padding(.leading, 64)
                                .lineLimit(2)
                        } else if let e = row.levelsError {
                            Text(e).font(caption).foregroundStyle(Palette.dim).padding(.leading, 64)
                        }
                    }
                }
                Text("cur/avg: \(linux.metricsFormat); DPM: pp_dpm_* levels, [current]")
                    .font(caption).foregroundStyle(Palette.dim).lineLimit(2)
            }
        }
    }

    private var sensorsPanel: some View {
        Panel(title: "Sensors (hwmon)") {
            VStack(alignment: .leading, spacing: 4) {
                if linux.sensors.isEmpty {
                    Text(linux.statusOK ? "no hwmon device found" : linux.status)
                        .font(caption).foregroundStyle(Palette.dim)
                }
                ForEach(linux.sensors) { row in
                    Meter(label: row.label, value: row.value, maxValue: row.maxValue, text: row.text,
                          color: row.label.hasPrefix("Temp") || row.label.hasPrefix("Power") ? Palette.warm : Palette.accent)
                        .help(row.source)
                }
            }
        }
    }

    private var throttlePanel: some View {
        Panel(title: "Throttling (gpu_metrics)") {
            VStack(alignment: .leading, spacing: 4) {
                if let bits = linux.throttleIndependent {
                    Text(linux.throttleActive.isEmpty ? "none active" : linux.throttleActive.joined(separator: " "))
                        .font(body11)
                        .foregroundStyle(linux.throttleActive.isEmpty ? Palette.umc : Palette.warm)
                    Text(String(format: "indep_throttle_status 0x%016llx", bits))
                        .font(caption).foregroundStyle(Palette.dim)
                } else {
                    Text("indep_throttle_status not reported").font(body11).foregroundStyle(Palette.dim)
                }
                if let raw = linux.throttleRaw {
                    Text(String(format: "throttle_status 0x%08llx (ASIC-specific bits)", raw))
                        .font(caption).foregroundStyle(Palette.dim)
                }
                Text("bit names: SMU_THROTTLER_* (amdgpu_smu.h)")
                    .font(caption).foregroundStyle(Palette.dim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pciePanel: some View {
        Panel(title: "PCIe link") {
            VStack(alignment: .leading, spacing: 4) {
                if linux.pcie.isEmpty {
                    Text("link status not reported").font(body11).foregroundStyle(Palette.dim)
                }
                ForEach(Array(linux.pcie.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.label).frame(width: 150, alignment: .leading).foregroundStyle(Palette.dim)
                        Text(row.text).foregroundStyle(Palette.bright)
                        Spacer()
                    }
                    .font(body11)
                }
                if !linux.pcieLevels.isEmpty {
                    Text("pp_dpm_pcie: " + linux.pcieLevels.map { ($0.active ? "[" : "") + $0.text + ($0.active ? "]" : "") }.joined(separator: "  "))
                        .font(caption).foregroundStyle(Palette.dim).lineLimit(2)
                }
                Text("endpoint: pci-sysfs current/max_link_*; through Thunderbolt this is the card's link to the enclosure, not the whole path")
                    .font(caption).foregroundStyle(Palette.dim).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
