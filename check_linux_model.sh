#!/bin/bash
# Offline check of the MacLinuxGPU model: no IOKit call, no driver.
#
# Usage: ./check_linux_model.sh [PATH/TO/kgd_pp_interface.h]
#   (default: third_party/kgd_pp_interface.h, the vendored upstream header)
#
# A C program fills upstream struct gpu_metrics_v1_3 the way the SMU code
# does (all-ones, then the header, then fields) and writes it out; the
# Swift decoder must find every field by the blob's header alone. The
# pp_dpm_* parser and the snapshot's labels, GRBM fraction and fallbacks
# are checked against fixed sysfs text.
set -euo pipefail
if [[ $# -gt 0 ]]; then
    header="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
fi
cd "$(dirname "$0")"
header="${header:-third_party/kgd_pp_interface.h}"
[[ -f "$header" ]] || { echo "$0: $header: no such file" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$header" "$work/metrics.c" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
def block(name):
    return re.search(r"^struct %s \{.*?^\};" % name, text, re.S | re.M).group(0)
defines = "\n".join(re.findall(r"^#define\s+(?:NUM|MAX)_\w+\s+\d+\s*$", text, re.M))
Path(sys.argv[2]).write_text(f"""#include <stdint.h>
#include <stdio.h>
#include <string.h>
{defines}
{block("metrics_table_header")}
{block("gpu_metrics_v1_3")}
int main(void) {{
    struct gpu_metrics_v1_3 m;
    memset(&m, 0xff, sizeof(m));
    m.common_header.structure_size = sizeof(m);
    m.common_header.format_revision = 1;
    m.common_header.content_revision = 3;
    m.temperature_edge = 45; m.temperature_hotspot = 61; m.average_gfx_activity = 37;
    m.average_umc_activity = 12; m.average_socket_power = 123; m.current_gfxclk = 2450;
    m.average_gfxclk_frequency = 2400; m.current_uclk = 1258; m.throttle_status = 0x10;
    m.indep_throttle_status = (1ull << 0) | (1ull << 36); m.pcie_link_width = 16; m.pcie_link_speed = 160;
    fwrite(&m, sizeof(m), 1, stdout);
    return 0;
}}
""")
PY
clang -std=c11 -o "$work/metrics" "$work/metrics.c"
"$work/metrics" > "$work/metrics.bin"

cat > "$work/main.swift" <<'SWIFT'
import Foundation
let blob = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
guard let m = GPUMetrics(bytes: blob), m.decoded else { fatalError("v1.3 not decoded") }
precondition(m.versionText == "v1.3" && m.structureSize == blob.count)
precondition(m.value("temperature_edge") == 45 && m.value("temperature_hotspot") == 61)
precondition(m.value("average_gfx_activity") == 37 && m.value("average_umc_activity") == 12)
precondition(m.value("current_gfxclk") == 2450 && m.value("average_gfxclk_frequency") == 2400)
precondition(m.value("current_uclk") == 1258 && m.value("throttle_status") == 0x10)
precondition(m.value("pcie_link_width") == 16 && m.value("pcie_link_speed") == 160)
precondition(m.value("temperature_mem") == nil && m.value("current_fan_speed") == nil)  // all-ones: absent
precondition(!m.has("temperature_gfx"))
// A header naming another struct, or a short blob, is not decoded.
var other = blob; other[3] = 9
precondition(GPUMetrics(bytes: other)?.decoded == false)
precondition(GPUMetrics(bytes: Array(blob.prefix(40)))?.decoded == false)

let levels = parseDPMLevels("S: 19Mhz *\n0: 500Mhz \n1: 2450Mhz \n")
precondition(levels.count == 3 && levels[0].label == "S" && levels[0].active && levels[2].mhz == 2450)
let pcie = parseDPMLevels("0: 2.5GT/s, x1 619Mhz \n1: 16.0GT/s, x16 1143Mhz *\n")
precondition(pcie[1].active && pcie[1].text == "16.0GT/s, x16 1143Mhz")

let s = LinuxSample()
s.modulesRunning = true
s.hwmon = "hwmon/hwmon0"
s.metrics = m
s.text = ["gpu_busy_percent": "88", "mem_busy_percent": "12",
          "mem_info_vram_used": "3221225472", "mem_info_vram_total": "34359738368",
          "pp_dpm_sclk": "0: 500Mhz \n1: 2450Mhz *", "current_link_speed": "16.0 GT/s PCIe",
          "current_link_width": "16", "vendor": "0x1002", "device": "0x7551",
          "hwmon/hwmon0/temp1_input": "45000", "hwmon/hwmon0/temp1_label": "edge",
          "hwmon/hwmon0/power1_average": "123000000", "hwmon/hwmon0/power1_cap": "300000000"]
let history = LinuxHistory()
var now: UInt64 = 10_000_000_000
history.add(s, nowNs: now)
var snap = makeLinuxSnapshot(s, history: history, nowNs: now)
precondition(snap.statusOK && !snap.coreHardware && snap.coreCurrent == 88)     // gpu_busy_percent
precondition(snap.memoryCurrent == 12 && snap.umcMetrics == 12)
precondition(snap.vram.map { abs($0.used - 3) < 1e-9 && abs($0.total - 32) < 1e-9 } == true)
precondition(snap.clocks[0].current == 2450 && snap.clocks[0].levels[1].active)
precondition(snap.throttleActive == ["PPT0", "TEMP_HOTSPOT"])
precondition(snap.sensors.first?.label == "Temp edge" && snap.sensors.first?.value == 45)
precondition(snap.sensors.contains { $0.label == "Power avg" && $0.text == "123 W / 300 W cap" })
precondition(snap.deviceLine == "1002:7551" && snap.linkLine == "PCIe 16.0 GT/s PCIe x16")
// Eight GRBM samples, six active: 75% from hardware sampling.
let grbmStart: UInt64 = now - 1_000_000
s.grbm = (0..<8).map { (i: Int) -> (atNs: UInt64, active: Bool) in
    (atNs: grbmStart + UInt64(i) * 10_000, active: i % 4 != 0)
}
now += 2_000_000
history.add(s, nowNs: now)
snap = makeLinuxSnapshot(s, history: history, nowNs: now)
precondition(snap.coreHardware && snap.coreCurrent == 75)
// Not running: no values, an honest status.
let idle = LinuxSample()
idle.notReady = true
idle.modulesRunning = false
history.add(idle, nowNs: now)
snap = makeLinuxSnapshot(idle, history: history, nowNs: now)
precondition(!snap.statusOK && snap.coreCurrent == nil && snap.status.hasPrefix("upstream amdgpu not running"))
// The dext's published identity and monitors, shown even while idle.
let device: [String: Any] = ["Name": "AMD Radeon AI Pro R9700", "VendorID": NSNumber(value: 0x1002),
                             "DeviceID": NSNumber(value: 0x7551), "VRAMBytes": NSNumber(value: UInt64(32) << 30),
                             "VRAMType": "GDDR6", "GFXTarget": "gfx1201", "VBIOSPartNumber": "113-EXAMPLE"]
let outputs: [String: Any] = ["HotplugEpoch": NSNumber(value: 2), "Connectors": [
    ["Name": "DP-4", "Status": "connected", "Monitor": "DELL UP2716D", "Lit": true,
     "LitWidth": NSNumber(value: 2560), "LitHeight": NSNumber(value: 1440), "LitRefresh": NSNumber(value: 60)],
    ["Name": "DP-5", "Status": "connected", "Lit": false,
     "PreferredWidth": NSNumber(value: 1920), "PreferredHeight": NSNumber(value: 1080)],
    ["Name": "HDMI-A-1", "Status": "disconnected", "Lit": false]] as [[String: Any]]]
idle.registry = LinuxRegistryInfo(device: device, displays: outputs)
snap = makeLinuxSnapshot(idle, history: history, nowNs: now)
precondition(snap.deviceName == "AMD Radeon AI Pro R9700 · 32 GiB GDDR6 · gfx1201")
precondition(snap.displays?.count == 3 && snap.displays?[0].monitor == "DELL UP2716D")
precondition(snap.displays?[0].mode == "2560x1440@60" && snap.displays?[0].driven == true)
precondition(snap.displays?[1].mode == "1920x1080" && snap.displays?[1].driven == false && snap.displays?[1].monitor == nil)
precondition(snap.displays?[2].connected == false)
precondition(LinuxRegistryInfo(device: nil, displays: outputs) == nil)
precondition(LinuxRegistryInfo(device: ["VendorID": NSNumber(value: 0x1002)], displays: nil)?.displays == nil)
print("PASS MacLinuxGPU model: gpu_metrics v1.3 by header, pp_dpm parsing, snapshot sources and fallbacks, published identity and displays")
SWIFT

xcrun swiftc -Onone -o "$work/check" "$work/main.swift" \
    Sources/GPUMetricsLayout.swift Sources/LinuxDriver.swift Sources/LinuxModel.swift \
    Sources/MonitorModel.swift Sources/GPUDriver.swift
"$work/check" "$work/metrics.bin"
