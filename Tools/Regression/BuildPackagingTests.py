#!/usr/bin/env python3
"""Controlled build/packaging integration checks; never touch /Applications.

Requires macOS system ditto/PlistBuddy plus Python 3 for tests only. The production
build script has no Python dependency. A copied build script uses a fake install
root and fake compiler/signing/launch commands; real ditto tests backup round trips.
All expanded fixtures live below a temporary .noindex directory.
"""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[2]
SCRIPT = (REPO / 'build.sh').read_text()
WORKFLOW = REPO / '.github/workflows/release.yml'
MOCK = r'''#!/usr/bin/env python3
from pathlib import Path
import os, sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ['FIXTURE_LOG']).open('a') as log:
    log.write(name + ' ' + ' '.join(args) + '\n')
if name == 'swiftc':
    out = Path(args[args.index('-o') + 1])
    if out.name == 'stop-installed':
        out.write_text('#!/bin/bash\nprintf "stop\\n" >> "$FIXTURE_LOG"\nif [ "${FIXTURE_RUNNING:-0}" = 1 ]; then touch "$1"; fi\nif [ "${FIXTURE_FAIL_STOP:-0}" = 1 ]; then exit 1; fi\n')
    else:
        out.write_text('new executable\n')
    out.chmod(0o755)
elif name == 'lipo':
    Path(args[args.index('-output') + 1]).write_text('new executable\n')
elif name == 'codesign':
    target = Path(args[-1])
    if '--sign' in args and os.environ.get('FIXTURE_FAIL') == 'sign':
        sys.exit(1)
    if '--verify' in args:
        if '.noindex/' in str(target) and os.environ.get('FIXTURE_FAIL') == 'candidate-verify':
            sys.exit(1)
        if target == Path(os.environ['FIXTURE_INSTALL']) / 'SysPulse.app' and os.environ.get('FIXTURE_FAIL') == 'installed-verify':
            sys.exit(1)
elif name == 'open':
    executable = Path(args[-1]) / 'Contents/MacOS/SysPulse'
    if os.environ.get('FIXTURE_FAIL') == 'launch' and executable.read_text() == 'new executable\n':
        sys.exit(1)
elif name == 'hdiutil':
    if args[0] == 'create':
        stage = Path(args[args.index('-srcfolder') + 1])
        assert '.noindex/' in str(stage)
        assert (stage / '.metadata_never_index').is_file()
        assert (stage / 'SysPulse.app/Contents/Info.plist').is_file()
        assert (stage / 'Applications').is_symlink()
        Path(args[-1]).write_bytes(b'controlled-dmg-fixture')
    elif args[0] == 'verify':
        assert Path(args[-1]).read_bytes() == b'controlled-dmg-fixture'
    else:
        raise SystemExit('Unexpected hdiutil command')
elif name == 'git':
    if args[:2] == ['rev-parse', '--short']:
        print('fixture')
    elif args[:2] == ['rev-list', '--count']:
        print('99')
    elif args[:2] == ['rev-parse', '--git-dir']:
        print('.git')
else:
    raise SystemExit('Unexpected mock command: ' + name)
'''


def check(condition, description):
    assert condition, description
    print('PASS:', description)


def fixture(root, label, *, local=False, failure='', running=True, no_launch=False, missing_install=False, fail_stop=False):
    case = root / label
    case.mkdir()
    repo = case / 'project'
    (repo / 'Sources/SysPulse').mkdir(parents=True)
    (repo / 'Sources/SysPulse/Stub.swift').write_text('fixture')
    (repo / 'Resources').mkdir()
    (repo / 'Resources/AppIcon.icns').write_bytes(b'fixture-icon')
    info = {'CFBundleShortVersionString': '9.8.7', 'CFBundleVersion': '1'}
    (repo / 'Resources/Info.plist').write_bytes(plistlib.dumps(info))
    install = case / 'Applications'
    install.mkdir()
    old = install / 'SysPulse.app'
    (old / 'Contents/MacOS').mkdir(parents=True)
    (old / 'Contents/MacOS/SysPulse').write_text('old executable\n')
    (old / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    # Only the copied script can use a fixture path. Production stays fixed.
    copied = SCRIPT.replace('INSTALL_DIR="/Applications"', 'INSTALL_DIR="' + str(install) + '"')
    if missing_install:
        copied = copied.replace('INSTALL_DIR="' + str(install) + '"', 'INSTALL_DIR="' + str(case / 'missing') + '"')
    script = repo / 'build.sh'
    script.write_text(copied)
    commands = case / 'commands'
    commands.mkdir()
    for name in ('swiftc', 'lipo', 'codesign', 'open', 'git'):
        tool = commands / name
        tool.write_text(MOCK)
        tool.chmod(0o755)
    temp = case / 'tmp'
    temp.mkdir()
    log = case / 'commands.log'
    log.write_text('')
    env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], TMPDIR=str(temp) + '/',
               FIXTURE_LOG=str(log), FIXTURE_INSTALL=str(install), FIXTURE_FAIL=failure,
               FIXTURE_RUNNING='1' if running else '0', FIXTURE_FAIL_STOP='1' if fail_stop else '0')
    args = ['bash', str(script)]
    if local:
        args.append('--local')
    if no_launch:
        args.append('--no-launch')
    result = subprocess.run(args, cwd=repo, env=env, capture_output=True, text=True, errors='replace')
    commands_run = log.read_text()
    check(not list(install.glob('.SysPulse-build.*.noindex')) and not list(temp.iterdir()), label + ': trap removes temporary expanded apps')
    actual = (old / 'Contents/MacOS/SysPulse').read_text()
    if local:
        check(result.returncode == 0, label + ': local archive succeeds: ' + result.stderr)
        archive = repo / 'dist/SysPulse.app.zip'
        with zipfile.ZipFile(archive) as zipped:
            check(zipped.read('SysPulse.app/Contents/MacOS/SysPulse') == b'new executable\n', label + ': real ditto archive contains new app')
        check(not list((repo / 'dist').glob('*.app')), label + ': no expanded local app')
        check(actual == 'old executable\n' and '\nstop\n' not in '\n' + commands_run and 'open ' not in commands_run, label + ': existing app untouched and no stop/launch')
    elif failure or missing_install or fail_stop:
        check(result.returncode != 0, label + ': failure is not reported as success')
        check(actual == 'old executable\n', label + ': original install preserved or restored')
        if failure in ('sign', 'candidate-verify') or missing_install:
            check('\nstop\n' not in '\n' + commands_run, label + ': does not stop old app before candidate verification')
        if failure in ('installed-verify', 'launch'):
            check('open ' in commands_run, label + ': restarts restored previously-running app')
    else:
        check(result.returncode == 0, label + ': install succeeds: ' + result.stderr)
        check(actual == 'new executable\n', label + ': candidate becomes only formal install')
        backups = list((repo / 'Backups').glob('*.zip'))
        check(len(backups) == 1 and not list((repo / 'Backups').glob('*.app')), label + ': only compressed old backup remains')
        with zipfile.ZipFile(backups[0]) as zipped:
            check(zipped.read('SysPulse.app/Contents/MacOS/SysPulse') == b'old executable\n', label + ': backup recovers exact old executable')
        check(('open ' not in commands_run) == no_launch, label + ': launch preference honored')
    for line in commands_run.splitlines():
        if line.startswith('codesign ') and ' --sign ' in line:
            check('.noindex/SysPulse.app' in line, label + ': expanded signing candidate is inside noindex')


def workflow_checks():
    output = subprocess.check_output(['ruby', '-rjson', '-ryaml', '-e', 'puts JSON.generate(YAML.load_file(ARGV[0]))', str(WORKFLOW)], text=True)
    workflow = json.loads(output)
    package_script = None
    for step in workflow['jobs']['release']['steps']:
        if 'run' not in step:
            continue
        subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True)
        for block in step['run'].split("python3 - <<'PY'\n")[1:]:
            compile(block.split('\nPY', 1)[0], step['name'], 'exec')
        if step['name'] == 'Package and verify DMG':
            package_script = step['run']
    check(package_script is not None and 'SysPulse-release.XXXXXX"' in package_script and 'RELEASE_TEMP="$RELEASE_TEMP.noindex"' in package_script and 'trap ' in package_script, 'CI temporary staging is noindex and trap-cleaned')
    check('.metadata_never_index' in package_script and 'release/staging/SysPulse.app' not in package_script, 'CI DMG root disables indexing and ordinary staging app removed')
    check(workflow['permissions'] == {'contents': 'write'}, 'CI retains release-only contents permission')
    print('PASS: workflow YAML, shell, and embedded Python syntax')
    with tempfile.TemporaryDirectory(prefix='SysPulse-ci-packaging.', suffix='.noindex') as directory:
        root = Path(directory)
        (root / 'Resources').mkdir()
        (root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '9.8.7', 'CFBundleVersion': '1'}))
        (root / 'Resources/AppIcon.icns').write_bytes(b'fixture-icon')
        (root / 'CHANGELOG.md').write_text('# Updates\n\n## Version\nFixture release notes\n')
        (root / 'build').mkdir()
        (root / 'build/SysPulse').write_text('new executable\n')
        commands = root / 'commands'
        commands.mkdir()
        for name in ('git', 'codesign', 'hdiutil'):
            executable = commands / name
            executable.write_text(MOCK)
            executable.chmod(0o755)
        runner_temp = root / 'runner-temp'
        runner_temp.mkdir()
        log = root / 'commands.log'
        log.write_text('')
        env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], RUNNER_TEMP=str(runner_temp),
                   GITHUB_REF_NAME='v9.8.7', GITHUB_SHA='123456789', FIXTURE_LOG=str(log), FIXTURE_INSTALL=str(root / 'Applications'))
        result = subprocess.run(['bash', '-c', package_script], cwd=root, env=env, capture_output=True, text=True, errors='replace')
        check(result.returncode == 0, 'CI packaging script executes successfully with controlled tools: ' + result.stderr)
        check(not list(runner_temp.iterdir()), 'CI packaging success trap removes expanded app')
        checksum = (root / 'release/SysPulse-9.8.7.dmg.sha256').read_text().split()
        check(checksum[1] == 'SysPulse-9.8.7.dmg', 'CI emits version-derived DMG and checksum')
        env['FIXTURE_FAIL'] = 'sign'
        result = subprocess.run(['bash', '-c', package_script], cwd=root, env=env, capture_output=True, text=True, errors='replace')
        check(result.returncode != 0 and not list(runner_temp.iterdir()), 'CI signing failure stops and cleans expanded app')
        env['FIXTURE_FAIL'] = ''
        env['GITHUB_REF_NAME'] = 'v0.0.0'
        result = subprocess.run(['bash', '-c', package_script], cwd=root, env=env, capture_output=True, text=True, errors='replace')
        check(result.returncode != 0 and not list(runner_temp.iterdir()), 'CI tag/version mismatch stops and cleans staging')


def main():
    subprocess.run(['bash', '-n', str(REPO / 'build.sh')], check=True)
    check('python3' not in SCRIPT and 'pkill' not in SCRIPT and 'pgrep' not in SCRIPT, 'production build has no Python or broad process-kill dependency')
    check('bundleURL?.standardizedFileURL == installed' in SCRIPT and 'executableURL?.standardizedFileURL == executable' in SCRIPT, 'stop helper requires exact formal bundle and executable paths')
    with tempfile.TemporaryDirectory(prefix='SysPulse-packaging-tests.', suffix='.noindex') as directory:
        root = Path(directory)
        check('.XXXXXX.noindex' not in SCRIPT and '.XXXXXX.noindex' not in WORKFLOW.read_text(), 'mktemp templates keep random X characters at the end')
        created = []
        for _ in range(2):
            raw = Path(subprocess.check_output(['/usr/bin/mktemp', '-d', str(root / 'uniqueness.XXXXXX')], text=True).strip())
            renamed = Path(str(raw) + '.noindex')
            raw.rename(renamed)
            created.append(renamed)
        check(created[0] != created[1] and all(path.is_dir() and path.name.endswith('.noindex') and 'XXXXXX' not in path.name for path in created), 'real BSD mktemp produces distinct concurrent noindex directories')
        for path in created:
            path.rmdir()
        helper = root / 'StopInstalled.swift'
        helper.write_text(SCRIPT.split("<<'SWIFT'\n", 1)[1].split('\nSWIFT', 1)[0])
        subprocess.run(['/usr/bin/swiftc', '-O', '-swift-version', '5', '-warnings-as-errors',
                        '-target', 'arm64-apple-macosx14.0', '-module-cache-path', str(root / 'modulecache'),
                        '-framework', 'AppKit', str(helper), '-o', str(root / 'stop-installed')], check=True)
        print('PASS: real precise-path Swift helper compiles; not executed')
        fixture(root, 'local', local=True)
        fixture(root, 'signature-failure', failure='sign')
        fixture(root, 'candidate-verify-failure', failure='candidate-verify')
        fixture(root, 'install-permission-failure', missing_install=True)
        fixture(root, 'installed-verify-rollback', failure='installed-verify')
        fixture(root, 'launch-rollback', failure='launch')
        fixture(root, 'stop-failure', fail_stop=True)
        fixture(root, 'install-success')
        fixture(root, 'install-no-launch', no_launch=True)
    workflow_checks()
    print('All controlled packaging checks passed; no real app installed or terminated.')


if __name__ == '__main__':
    main()
