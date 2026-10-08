from pathlib import Path
import platform
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUTPUT = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / 'build/regression/presentation'
OUTPUT.mkdir(parents=True, exist_ok=True)

def block(text, signature):
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
    '    private func beginClosePresentation(',
    '    private func reopenPresentation(',
    '    private func finishOpenPresentation(',
    '    @objc private func togglePopover(',
]]
source = (REPO / 'Sources/SysPulse/PanelPresentationAnimation.swift').read_text()
animation = block(source, 'final class PanelPresentationAnimation')
scaffold = (HERE / 'PresentationScaffold.swift.in').read_text()
checks = (HERE / 'PresentationChecks.swift.in').read_text()
path = OUTPUT / 'PresentationUnderTest.swift'
path.write_text(scaffold + '\n'.join(methods) + '\n}\n' + animation + '\n' + checks)
subprocess.run([
    'swiftc', '-parse-as-library', '-O', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx14.0',
    '-warnings-as-errors', '-framework', 'AppKit', '-framework', 'QuartzCore',
    '-module-cache-path', str(OUTPUT / 'modulecache'), str(path), '-o', str(OUTPUT / 'PresentationStateTests')
], check=True)
subprocess.run([str(OUTPUT / 'PresentationStateTests')], check=True)
