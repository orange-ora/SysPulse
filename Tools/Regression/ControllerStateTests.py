"""Exercise real GPU-width and glass lifecycle bodies with fake coordinates.

No NSStatusItem, real windows, installed app, or UserDefaults are created.
The real glass view is instantiated only in a detached NSView container.
The compiler also builds the full controller in run.sh's primary test phase;
this separate phase supplies deterministic window geometry for its state pipeline.
"""
from pathlib import Path
import platform
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUTPUT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / 'build/regression/controller'
OUTPUT.mkdir(parents=True, exist_ok=True)


def block(text, signature):
    """Extract current source bodies, never a hand-maintained copy of the logic."""
    start = text.index(signature)
    begin = text.index('{', start)
    depth, cursor = 1, begin + 1
    while depth:
        if text[cursor] == '{':
            depth += 1
        elif text[cursor] == '}':
            depth -= 1
        cursor += 1
    return text[start:cursor]


controller = (REPO / 'Sources/SysPulse/StatusItemController.swift').read_text()
methods = [block(controller, signature) for signature in [
    '    static func gpuWidthState(',
    '    private func updateStatusItem(',
    '    private struct TextImageKey',
    '    private func textImage(',
    '    private func applyMenuBarImage(',
    '    private func primeDensityWidths(',
    '    private var ceilingIndex:',
    '    private var currentDensityIndex:',
    '    private func adaptToAvailableSpace(',
    '    static func memoryTint(',
    '    static func tint(',
]]
monitors = (REPO / 'Sources/SysPulse/Monitors.swift').read_text()
metrics = block(monitors, 'struct MetricsSnapshot')
pressure = block(monitors, 'enum MemoryPressure')
(OUTPUT / 'MetricsSnapshot.swift').write_text('import Foundation\n' + pressure + '\n' + metrics + '\n')
scaffold = (HERE / 'ControllerScaffold.swift.in').read_text()
checks = (HERE / 'ControllerChecks.swift.in').read_text()
glass_view = block(controller, 'private final class StatusItemGlassView: NSView')
glass_checks = (HERE / 'GlassHoverChecks.swift.in').read_text()
(OUTPUT / 'ControllerUnderTest.swift').write_text(scaffold + '\n'.join(methods) + '\n' + checks + '\n}\n' + glass_view + '\n' + glass_checks)
(OUTPUT / 'ExtractedMethods.swift.txt').write_text('\n'.join(methods) + '\n' + glass_view)
(OUTPUT / 'Entry.swift').write_text('import Darwin\n@main struct Entry { static func main() { setbuf(stdout, nil); StatusItemController.runChecks() } }\n')

subprocess.run([
    'swiftc', '-O', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx14.0',
    '-warnings-as-errors', '-framework', 'AppKit', '-module-cache-path', str(OUTPUT / 'modulecache'),
    str(OUTPUT / 'MetricsSnapshot.swift'), str(OUTPUT / 'ControllerUnderTest.swift'),
    str(REPO / 'Sources/SysPulse/MenuBarImage.swift'), str(REPO / 'Sources/SysPulse/Formatting.swift'),
    str(OUTPUT / 'Entry.swift'), '-o', str(OUTPUT / 'ControllerStateTests'),
], check=True)
subprocess.run([str(OUTPUT / 'ControllerStateTests')], check=True)
