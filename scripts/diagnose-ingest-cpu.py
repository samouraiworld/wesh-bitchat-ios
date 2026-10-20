#!/usr/bin/env python3
"""One collection-only cloud invocation; ALWAYS INCOMPLETE until private review.

No raw stdout/stderr is forwarded. The only uploadable files are authenticated
CMS ciphertext and a neutral allowlisted manifest. Unsupported tool/schema or
missing actual child proof remains incomplete. This collector never automatically
certifies sample ownership, clocks or diagnostic success, even with a trace file.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

BASE = '53601696839ab7f73e902de88115f2bd8e066dea'
CERT_SHA = '38457ef69f8ae2e754224d562ccc1e4d2e60508b6f6c717e258135e8d248a9fe'
ADDITIONS = {'.github/workflows/ingest-cpu-diagnostic.yml',
             '.github/diagnostics/ingest-cpu-recipient.pem',
             'scripts/diagnose-ingest-cpu.py'}
RAW_LIMIT = 512 * 1024 * 1024
CIPHER_LIMIT = 256 * 1024 * 1024
BENCH_SECONDS = 360
TRACE_SECONDS = 420
TRACE_FINALIZE_SECONDS = 90
STOP = False


class Incomplete(Exception):
    pass


def interrupted(_sig, _frame):
    global STOP
    STOP = True


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


class Run:
    def __init__(self):
        self.repo = Path.cwd().resolve()
        self.out = self.repo / '.diagnostic-upload'
        if self.out.exists():
            raise Incomplete('existing-output')
        self.out.mkdir(mode=0o700)
        self.root = Path(tempfile.mkdtemp(prefix='ingest-cpu-', dir=os.environ['RUNNER_TEMP']))
        self.root.chmod(0o700)
        self.raw = self.root / 'raw'
        self.raw.mkdir(mode=0o700)
        self.processes = []
        self.files = []
        self.events = []
        self.errors = []
        self.notifier = None
        self.observer = None
        self.recorder = None
        self.serial = None
        self.case_count = 0
        self.sequence = 0
        self.binpath = None
        self.epoch = time.monotonic()

    def note(self, kind, **values):
        self.events.append({'elapsed': time.monotonic() - self.epoch, 'kind': kind, **values})

    def size(self):
        # Symlinks never expand collection outside the owned directory.
        total = 0
        for p in self.root.rglob('*'):
            if p.is_symlink():
                raise Incomplete('raw-symlink')
            if p.is_file():
                total += p.stat().st_size
        return total

    def guard(self):
        if STOP:
            raise Incomplete('interrupted')
        if self.size() > RAW_LIMIT:
            raise Incomplete('raw-budget')

    def spawn(self, args, name, env=None, stdin=None, stdout=None, scratch=False):
        self.sequence += 1
        log = (self.root if scratch else self.raw) / f'{self.sequence:02d}-{name}.log'
        f = log.open('wb')
        self.files.append(f)
        p = subprocess.Popen(args, cwd=self.repo, env=env, stdin=stdin,
                             stdout=stdout if stdout is not None else f,
                             stderr=f, start_new_session=True)
        self.processes.append((p, p.pid, name))
        self.note('spawn', name=name, pid=p.pid, args=args)
        return p, log

    def wait(self, p, seconds, *, started_at=None):
        deadline = (time.monotonic() if started_at is None else started_at) + seconds
        while p.poll() is None:
            self.guard()
            if time.monotonic() >= deadline:
                raise Incomplete('process-budget')
            time.sleep(0.1)
        self.guard()
        self.note('exit', pid=p.pid, returncode=p.returncode)
        if self.group_exists(p.pid):
            raise Incomplete('descendant-outlived-command')
        self.processes = [row for row in self.processes if row[0] is not p]
        if p.returncode != 0:
            raise Incomplete('process-failed')

    def command(self, args, name, seconds=60, env=None, stdout_only=False):
        # Path-valued stdout must not be contaminated by benign tool stderr.
        # Both streams are still preserved privately.
        output = None
        destination = None
        if stdout_only:
            destination = self.raw / f'{self.sequence + 1:02d}-{name}.stdout'
            output = destination.open('wb')
            self.files.append(output)
        p, log = self.spawn(args, name, env=env, stdout=output)
        self.wait(p, seconds)
        if output is not None:
            output.close()
        return (destination if destination is not None else log).read_text(errors='replace')

    @staticmethod
    def group_exists(pgid):
        try:
            os.killpg(pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def stop_group(self, p, pgid, name, orderly=False):
        # Never poll/kill by name; direct-child return alone does not certify
        # its descendants. Escalation preserves an incomplete classification.
        for sig, seconds in [(signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 5)]:
            if not self.group_exists(pgid):
                break
            if sig != signal.SIGINT or not orderly:
                self.errors.append('forced-' + name)
            try:
                os.killpg(pgid, sig)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline and self.group_exists(pgid):
                p.poll()  # Reap this actual direct child if it has returned.
                time.sleep(0.05)
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.errors.append('unreaped-' + name)
        if self.group_exists(pgid):
            self.errors.append('unresolved-group-' + name)
        self.note('cleanup-process', name=name, pid=p.pid, returncode=p.poll())
        if p.returncode is not None and not self.group_exists(pgid):
            self.processes = [row for row in self.processes if row[0] is not p]

    def cleanup_processes(self):
        # All actual direct children/groups are attempted independently.
        for p, pgid, name in reversed(list(self.processes)):
            try:
                if p.poll() is None or self.group_exists(pgid):
                    self.stop_group(p, pgid, name, orderly=(p is self.recorder))
                else:
                    p.wait(timeout=2)
                    self.processes = [row for row in self.processes if row[0] is not p]
            except Exception as e:
                self.errors.append('cleanup-' + type(e).__name__)
        if self.notifier is not None:
            try:
                self.notifier.close()
            except BaseException as e:
                self.errors.append('notify-close-' + type(e).__name__)
            # Never forget a registration while its actual release is unknown.
            # A later successful retry cannot erase the sticky failed release.
            if self.notifier.closed and not self.notifier.release_unknown:
                self.notifier = None
        if self.observer is not None:
            try:
                self.observer.close()
            except Exception as e:
                self.errors.append('process-observer-close-' + type(e).__name__)
            self.observer = None
        for f in self.files:
            if not f.closed:
                try:
                    f.flush()
                except Exception as e:
                    self.errors.append('flush-' + type(e).__name__)
        self.note('all-owned-process-cleanup-attempted', errors=list(self.errors))

    def verify_source(self):
        actual = self.command(['git', 'rev-parse', 'HEAD'], 'head').strip()
        if actual != os.environ.get('DIAGNOSTIC_HEAD') or not re.fullmatch('[0-9a-f]{40}', actual):
            raise Incomplete('head-binding')
        changes = self.command(['git', 'diff', '--name-status', BASE, actual], 'source-diff')
        rows = [line.split('\t') for line in changes.splitlines()]
        if len(rows) != 3 or any(row[0] != 'A' for row in rows) or {row[1] for row in rows} != ADDITIONS:
            raise Incomplete('source-scope')
        if self.command(['git', 'status', '--porcelain', '--untracked-files=no'], 'tracked-clean').strip():
            raise Incomplete('dirty-source')
        cert = self.repo / '.github/diagnostics/ingest-cpu-recipient.pem'
        if digest(cert) != CERT_SHA or b'PRIVATE KEY' in cert.read_bytes():
            raise Incomplete('certificate-binding')
        return actual, cert

    def prelude(self):
        # Same app commands/order; all outputs stay inside ciphertext.
        self.command(['swift', '--version'], 'swift-version')
        self.command(['xcodebuild', '-version'], 'xcode-version')
        self.command(['swift', 'build', '--build-tests', '--enable-code-coverage', '--package-path', '.'],
                     'coverage-build', seconds=900)
        binpath = Path(self.command(['swift', 'build', '--show-bin-path', '--package-path', '.'], 'binpath', stdout_only=True).strip())
        catalog = self.repo / 'bitchat/Views/Wesh/Pave/Pave.xcstrings'
        bundle = binpath / 'bitchat_bitchat.bundle'
        catalogs = list(bundle.rglob('Pave.xcstrings'))
        if len(catalogs) != 1 or catalogs[0].read_bytes() != catalog.read_bytes() or catalogs[0].parent not in (bundle, bundle / 'Contents/Resources'):
            raise Incomplete('localization-input')
        directory = catalogs[0].parent
        self.command(['xcrun', 'xcstringstool', 'compile', str(catalog), '--output-directory', str(directory),
                      '--language', 'en', '--language', 'fr', '--format', 'stringsAndStringsdict'], 'localization')
        if any(not (directory / f'{lang}.lproj' / name).is_file() or not (directory / f'{lang}.lproj' / name).stat().st_size
               for lang in ('en', 'fr') for name in ('Pave.strings', 'Pave.stringsdict')):
            raise Incomplete('localization-output')
        env = dict(os.environ, BITCHAT_SKIP_PERF_BASELINES='1')
        self.command(['swift', 'test', '--skip-build', '--parallel', '--quiet', '--enable-code-coverage',
                      '--skip', 'PerformanceBaselineTests', '--package-path', '.'], 'parallel-functional', seconds=300, env=env)
        # Coverage summary precedes the real noncoverage rebuild.
        binpath = Path(self.command(['swift', 'build', '--show-bin-path', '--package-path', '.'], 'coverage-binpath', stdout_only=True).strip())
        self.binpath = binpath
        bundles = list(binpath.glob('*.xctest'))
        if len(bundles) != 1:
            raise Incomplete('coverage-bundle')
        binary = bundles[0] / 'Contents/MacOS' / bundles[0].stem
        prof = binpath / 'codecov/default.profdata'
        if not binary.is_file() or not prof.is_file():
            raise Incomplete('coverage-profile')
        self.command(['xcrun', 'llvm-cov', 'report', str(binary), '-instr-profile', str(prof),
                      '-ignore-filename-regex=(Tests|\\.build|checkouts|Mocks|_PreviewHelpers)'], 'coverage-summary')

    def profile(self):
        record_help = self.command(['xcrun', 'xctrace', 'help', 'record'], 'record-help')
        self.export_help = self.command(['xcrun', 'xctrace', 'help', 'export'], 'export-help')
        self.command(['man', '-P', 'cat', 'xctrace'], 'installed-manual')
        templates = self.command(['xcrun', 'xctrace', 'list', 'templates'], 'templates')
        required = ['--all-processes', '--time-limit', '--notify-tracing-started', '--no-prompt', '--template', '--output']
        if any(flag not in record_help for flag in required) or 'Time Profiler' not in templates:
            raise Incomplete('unsupported-record-tool')
        if '--toc' not in self.export_help or '--xpath' not in self.export_help:
            raise Incomplete('unsupported-export-tool')
        name = 'org.example.ingest-cpu.' + uuid.uuid4().hex
        self.notifier = Notification(name)  # Register-only; statusOK BEFORE spawn.
        # Run owns the exact registered descriptor/token before this fallible step.
        self.notifier.set_noninheritable()
        trace = self.raw / 'first-serial.trace'
        # Deliberately no sudo fallback: current admin user must be supported.
        # Permissions failure is incomplete, never security-setting mutation.
        self.recorder, _ = self.spawn(['xcrun', 'xctrace', 'record', '--template', 'Time Profiler',
                                      '--all-processes', '--time-limit', '420s', '--output', str(trace),
                                      '--no-prompt', '--notify-tracing-started', name], 'recorder')
        trace_start = time.monotonic()
        self.notifier.wait(self, self.recorder, seconds=30)
        env = dict(os.environ, BITCHAT_PERF_LOG=str(self.raw / 'perf-output.log'))
        # FIRST and ONLY serial command, including coverage→noncoverage build.
        self.serial, serial_log = self.spawn(['swift', 'test', '--quiet', '--filter', 'PerformanceBaselineTests'],
                                             'first-serial', env=env)
        serial_start = time.monotonic()
        try:
            self.observer = ProcessObservation(self, self.serial)
        except Exception as e:
            self.note('process-observer-unavailable', reason=type(e).__name__ + ':' + str(e))
        while self.serial.poll() is None:
            self.guard()
            if self.observer is not None:
                try:
                    self.observer.scan()
                except Exception as e:
                    self.note('process-observer-gap', reason=type(e).__name__ + ':' + str(e))
            if self.recorder.poll() is not None:
                raise Incomplete('recorder-ended-before-command')
            if time.monotonic() - trace_start > TRACE_SECONDS or time.monotonic() - serial_start > BENCH_SECONDS:
                raise Incomplete('capture-budget')
            time.sleep(0.1)
        if self.serial.returncode != 0:
            raise Incomplete('serial-failed')
        self.note('serial-return', returncode=self.serial.returncode)
        self.note('recorder-natural-finalization', absolute_deadline=trace_start - self.epoch + TRACE_SECONDS + TRACE_FINALIZE_SECONDS)
        self.wait(self.recorder, TRACE_SECONDS + TRACE_FINALIZE_SECONDS, started_at=trace_start)
        if self.errors or self.recorder.returncode != 0:
            raise Incomplete('recorder-incomplete')
        self.notifier.close()
        if not self.notifier.release_unknown:
            self.notifier = None
        text = serial_log.read_text(errors='replace')
        rows = re.findall(r"Test Case '([^']+)' passed \(", text)
        expected = re.findall(r'func (test\w+)\(', (self.repo / 'bitchatTests/Performance/PerformanceBaselineTests.swift').read_text())
        actual = [x.rsplit(' ', 1)[-1].rstrip(']') for x in rows]
        if len(expected) != 11 or len(rows) != 11 or sorted(actual) != sorted(expected):
            raise Incomplete('serial-case-inventory')
        self.case_count = len(rows)
        metrics = re.findall(r'PERF\[([^\]]+)\]:\s*([0-9.]+)\s*(\S+)/sec', text)
        floors = json.loads((self.repo / 'bitchatTests/Performance/perf-floors.json').read_text())['floors']
        if len(metrics) != 10 or {x[0] for x in metrics} != set(floors):
            raise Incomplete('metric-inventory')
        # Values are preserved, NEVER evaluated as qualification or selected.
        self.note('serial-inventory', cases=rows, measurements=metrics)
        self.export_samples(trace)

    def export_samples(self, trace):
        # Preserve actual tool data; do not guess a timestamp origin/unit or
        # certify a PID by differentPID + image + symbol. Private review later.
        toc_text = self.command(['xcrun', 'xctrace', 'export', '--input', str(trace), '--toc'],
                                'trace-toc', stdout_only=True)
        toc = ET.fromstring(toc_text)
        strict_xml_graph(toc)
        tables = [(run, table) for run in toc.findall('.//run') for table in run.findall('.//table')]
        selected = [(run, table) for run, table in tables if table.get('schema') == 'time-profile']
        if len(selected) != 1:
            raise Incomplete('unsupported-or-ambiguous-sample-schema')
        run, table = selected[0]
        number = run.get('number')
        schema = table.get('schema')
        if not number or not number.isdecimal() or schema != 'time-profile':
            raise Incomplete('unsupported-toc')
        xpath = f'/trace-toc/run[@number="{number}"]/data/table[@schema="{schema}"]'
        xml = self.command(['xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath', xpath],
                           'cpu-rows', seconds=90, stdout_only=True)
        # Both raw TOC and CPU XML are already retained even when this static
        # graph analysis fails. No invalid graph may be partially certified.
        try:
            document = ET.fromstring(xml)
            strict_xml_graph(document)
            self.note('export-graph-valid-unverified', physical_row_count=len(document.findall('.//row')),
                      sample_clock_mapping='UNKNOWN', child_sample_ownership='NOT_VERIFIED')
        except Exception as e:
            self.note('export-graph-invalid', reason=type(e).__name__ + ':' + str(e))
        self.collect_built_image()
        self.note('collection-only', disposition='ALWAYS_INCOMPLETE_PENDING_PRIVATE_CHILD_AND_CLOCK_PROOF')

    def collect_built_image(self):
        if self.binpath is None:
            raise Incomplete('missing-original-binpath')
        candidates = [p for p in self.binpath.glob('*.xctest/Contents/MacOS/*') if p.is_file() and not p.is_symlink()]
        if len(candidates) != 1:
            raise Incomplete('ambiguous-built-test-image')
        binary = candidates[0].resolve()
        uuid_text = self.command(['xcrun', 'dwarfdump', '--uuid', str(binary)], 'actual-image-uuid')
        self.note('built-image-unverified', image=str(binary), sha256=digest(binary), uuid_output=uuid_text)
        if binary.stat().st_size > RAW_LIMIT // 2 or self.size() + binary.stat().st_size > RAW_LIMIT:
            raise Incomplete('symbol-material-budget')
        shutil.copyfile(binary, self.raw / 'built-test-image')
        self.guard()

    def encrypt(self, cert, head, complete):
        # Seal collection BEFORE archiving: archive/encrypt diagnostics are
        # outside raw, so the archive cannot contain its own changing output.
        # On crypto failure these private scratch errors are disposed, never
        # uploaded raw or represented as a successful encrypted report.
        complete = False  # Collection-only: no automatic complete path.
        openssl = Path('/opt/homebrew/opt/openssl@3/bin/openssl')
        if not openssl.is_file():
            raise Incomplete('openssl3-unavailable')
        version = self.command([str(openssl), 'version'], 'openssl-version', stdout_only=True)
        if not version.startswith('OpenSSL 3.'):
            raise Incomplete('openssl3-required')
        (self.raw / 'private-manifest.json').write_text(json.dumps({'head': head, 'complete': complete,
                       'events': self.events, 'errors': self.errors}, indent=2))
        self.guard()
        for f in self.files:
            f.close()
        partial = self.root / 'ciphertext.partial'
        staged = self.out / '.pending.cms'  # Not in workflow upload allowlist.
        pipe, _ = self.spawn(['/usr/bin/tar', '-czf', '-', '-C', str(self.root), 'raw'],
                             'archive', stdout=subprocess.PIPE, scratch=True)
        try:
            enc, _ = self.spawn([str(openssl), 'cms', '-encrypt', '-binary', '-stream', '-outform', 'DER',
                                 '-aes-256-gcm', '-recip', str(cert), '-keyopt', 'rsa_padding_mode:oaep',
                                 '-keyopt', 'rsa_oaep_md:sha256', '-keyopt', 'rsa_mgf1_md:sha256',
                                 '-out', str(partial)], 'encrypt', stdin=pipe.stdout, scratch=True)
            pipe.stdout.close()
            deadline = time.monotonic() + 120
            while enc.poll() is None or pipe.poll() is None:
                if STOP or time.monotonic() > deadline or (partial.exists() and partial.stat().st_size > CIPHER_LIMIT):
                    raise Incomplete('encryption-budget')
                time.sleep(0.1)
            if pipe.returncode != 0 or enc.returncode != 0 or not partial.is_file() or not 0 < partial.stat().st_size <= CIPHER_LIMIT:
                raise Incomplete('archive-or-encryption-failed')
            os.replace(partial, staged)
            manifest = {'source_commit': head, 'kind': 'diagnostic-only-never-qualification',
                        'status': 'incomplete', 'ciphertext_sha256': digest(staged),
                        'ciphertext_bytes': staged.stat().st_size, 'certificate_sha256': CERT_SHA,
                        'sample_ownership_verified': False, 'serial_case_count': self.case_count}
            return False, manifest
        except BaseException:
            partial.unlink(missing_ok=True)
            staged.unlink(missing_ok=True)
            raise
        finally:
            if pipe.stdout is not None:
                pipe.stdout.close()

    def publish(self, manifest, complete):
        # Called ONLY after process cleanup and owned plaintext removal succeed.
        staged = self.out / '.pending.cms'
        cleanup_gaps = ('notify-close-', 'process-observer-close-', 'unreaped-', 'unresolved-group-', 'cleanup-')
        if (self.processes or self.root.exists() or self.notifier is not None or
                any(e.startswith(cleanup_gaps) for e in self.errors)):
            raise Incomplete('cleanup-not-complete')
        if {p.name for p in self.out.iterdir()} != {'.pending.cms'}:
            raise Incomplete('upload-allowlist')
        if digest(staged) != manifest['ciphertext_sha256'] or staged.stat().st_size != manifest['ciphertext_bytes']:
            raise Incomplete('ciphertext-publication-binding')
        os.replace(staged, self.out / 'ingest-cpu.cms')
        temporary = self.out / '.manifest.partial'
        temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        os.replace(temporary, self.out / 'manifest.json')
        if {p.name for p in self.out.iterdir()} != {'ingest-cpu.cms', 'manifest.json'}:
            raise Incomplete('upload-allowlist')


def strict_xml_graph(document):
    """Validate ALL nodes/ID/ref edges before any analysis; no silent loss."""
    nodes = list(document.iter())
    ids = {}
    for node in nodes:
        if 'id' in node.attrib:
            key = node.get('id')
            if not key or key in ids:
                raise Incomplete('duplicate-or-empty-XML-ID')
            ids[key] = node
        if 'ref' in node.attrib and (not node.get('ref') or 'id' in node.attrib):
            raise Incomplete('ambiguous-XML-reference')
    edges = {}
    for node in nodes:
        successors = list(node)
        if 'ref' in node.attrib:
            key = node.get('ref')
            if key not in ids:
                raise Incomplete('missing-XML-reference')
            successors.append(ids[key])
        edges[id(node)] = successors
    # Iterative three-colour DFS: shared DAGs are valid, active-path revisits
    # are cycles. Validate every node, not only a surviving successful frame.
    colours = {}
    for origin in nodes:
        if colours.get(id(origin)) == 2:
            continue
        stack = [(origin, False)]
        while stack:
            node, leaving = stack.pop()
            key = id(node)
            if leaving:
                colours[key] = 2
                continue
            colour = colours.get(key, 0)
            if colour == 1:
                raise Incomplete('cyclic-XML-provenance')
            if colour == 2:
                continue
            colours[key] = 1
            stack.append((node, True))
            stack.extend((child, False) for child in reversed(edges[key]))
    return ids


class ProcBSDInfo(ctypes.Structure):
    # Public Darwin proc_info.h; reject ABI mismatch rather than truncate.
    _fields_ = [(n, ctypes.c_uint32) for n in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(n, ctypes.c_uint32) for n in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


class ProcessObservation:
    """Owned invocation observations ONLY; never sample attribution/clock proof.

    The public APIs are read-only. Fork tracking NOTE_TRACK/CHILD is explicitly
    NOT used on Darwin. Gaps remain recorded, never inferred as absence.
    """
    def __init__(self, run, parent):
        self.run = run
        self.parent = parent
        self.library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.library.proc_pidinfo.restype = ctypes.c_int
        self.library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.library.proc_pidpath.restype = ctypes.c_int
        self.library.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.library.proc_listchildpids.restype = ctypes.c_int
        if ctypes.sizeof(ProcBSDInfo) != 136:
            raise Incomplete('process-ABI')
        self.root_identity = self.read(parent.pid)
        if self.root_identity['pgid'] != parent.pid or parent.poll() is not None:
            raise Incomplete('serial-process-observation-gap')
        self.records = {}
        self.watchers = {}
        self.next_cookie = 1
        self.rejected_count = 0
        self.rejected_budget_exhausted = False
        self.closed = False
        self.queue = select.kqueue()
        run.note('serial-process-identity', identity=self.root_identity)

    def read(self, pid):
        value = ProcBSDInfo()
        if self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(value), ctypes.sizeof(value)) != ctypes.sizeof(value):
            raise Incomplete('process-read-gap')
        if value.pid != pid or value.start_sec == 0 or value.start_usec >= 1000000:
            raise Incomplete('process-identity-framing')
        path = ctypes.create_string_buffer(4096)
        if self.library.proc_pidpath(pid, path, len(path)) <= 0:
            raise Incomplete('process-path-gap')
        check = ProcBSDInfo()
        if self.library.proc_pidinfo(pid, 3, 0, ctypes.byref(check), ctypes.sizeof(check)) != ctypes.sizeof(check):
            raise Incomplete('process-read-gap')
        before = (value.pid, value.ppid, value.pgid, value.start_sec, value.start_usec)
        after = (check.pid, check.ppid, check.pgid, check.start_sec, check.start_usec)
        if before != after:
            raise Incomplete('process-changed-during-read')
        return {'pid': pid, 'ppid': value.ppid, 'pgid': value.pgid,
                'birth_sec': value.start_sec, 'birth_usec': value.start_usec,
                'path': path.value.decode('utf-8', errors='strict')}

    @staticmethod
    def identity(value):
        return (value['pid'], value['birth_sec'], value['birth_usec'])

    @staticmethod
    def copy_rejected_identity(value):
        # Copy ONLY the exact primitive schema returned by read(), never an
        # arbitrary mapping, accepted-record dictionary or authority object.
        fields = ('pid', 'ppid', 'pgid', 'birth_sec', 'birth_usec', 'path')
        if (type(value) is not dict or len(value) != 6 or
                any(type(key) is not str for key in value) or
                any(key not in value for key in fields)):
            return None
        pid, ppid, pgid = value['pid'], value['ppid'], value['pgid']
        birth_sec, birth_usec, path = value['birth_sec'], value['birth_usec'], value['path']
        if (type(pid) is not int or not 0 < pid <= 0x7fffffff or
                type(ppid) is not int or not 0 <= ppid <= 0xffffffff or
                type(pgid) is not int or not 0 <= pgid <= 0xffffffff or
                type(birth_sec) is not int or not 0 < birth_sec <= 0xffffffffffffffff or
                type(birth_usec) is not int or not 0 <= birth_usec < 1000000 or
                type(path) is not str):
            return None
        try:
            path_bytes = path.encode('utf-8', errors='strict')
        except UnicodeEncodeError:
            return None
        if len(path_bytes) > 4095 or '\x00' in path:
            return None
        return {'pid': pid, 'ppid': ppid, 'pgid': pgid,
                'birth_sec': birth_sec, 'birth_usec': birth_usec, 'path': path}

    def remember_rejected(self, child, parent, again, chain,
                          child_parent_mismatch, child_group_mismatch, parent_identity_mismatch):
        # First128 TOTAL rejected calls, including duplicates; NO dedupe/key
        # ledger. Further ordinary combined rejection gaps remain unchanged.
        if self.rejected_count >= 128:
            if not self.rejected_budget_exhausted:
                self.rejected_budget_exhausted = True
                self.run.note('rejected-process-observation-budget-exhausted', limit=128)
            return
        self.rejected_count += 1
        child_copy = self.copy_rejected_identity(child)
        parent_copy = self.copy_rejected_identity(parent)
        again_copy = self.copy_rejected_identity(again)
        chain_copy = None
        if type(chain) is list and len(chain) <= 16:
            chain_copy = [self.copy_rejected_identity(value) for value in chain]
        predicates = (child_parent_mismatch, child_group_mismatch, parent_identity_mismatch)
        if (child_copy is None or parent_copy is None or again_copy is None or
                chain_copy is None or any(value is None for value in chain_copy) or
                any(type(value) is not bool for value in predicates)):
            # Explicit private schema limitation, not a silent lost event and
            # NEVER admission. The SAME caller rejection still follows.
            self.run.note('rejected-process-observation-schema-unavailable',
                          receipt_monotonic=time.monotonic(), receipt_wall_ns=time.time_ns())
            return
        self.run.note('rejected-process-observation', child=child_copy,
                      original_parent=parent_copy, reread_parent=again_copy,
                      previously_observed_chain=chain_copy,
                      child_parent_mismatch=child_parent_mismatch,
                      child_group_mismatch=child_group_mismatch,
                      parent_identity_mismatch=parent_identity_mismatch,
                      receipt_monotonic=time.monotonic(), receipt_wall_ns=time.time_ns())

    def scan(self):
        # Bounded live discovery, not complete fork census. A vanished process
        # or unresolved chain is a gap; no PID-only success predicate exists.
        self.drain_events()
        if self.parent.poll() is not None:
            return
        if self.identity(self.read(self.parent.pid)) != self.identity(self.root_identity):
            raise Incomplete('original-serial-process-changed')
        pending = [(self.root_identity, [])]
        count = 0
        seen = set()
        while pending:
            parent, chain = pending.pop()
            if self.identity(parent) in seen:
                raise Incomplete('process-chain-cycle')
            seen.add(self.identity(parent))
            count += 1
            if count > 128 or len(chain) > 16:
                raise Incomplete('process-observation-budget')
            buffer = (ctypes.c_int * 128)()
            # Apple's proc_listchildpids wrapper returns PID count, not bytes.
            actual = self.library.proc_listchildpids(parent['pid'], buffer, ctypes.sizeof(buffer))
            if actual < 0 or actual >= len(buffer):
                raise Incomplete('child-list-unavailable-or-truncated')
            for pid in buffer[:actual]:
                if pid <= 0:
                    raise Incomplete('child-list-framing')
                try:
                    child = self.read(pid)
                    again = self.read(parent['pid'])
                    child_parent_mismatch = child['ppid'] != parent['pid']
                    child_group_mismatch = child['pgid'] != self.root_identity['pgid']
                    parent_identity_mismatch = self.identity(again) != self.identity(parent)
                    if child_parent_mismatch or child_group_mismatch or parent_identity_mismatch:
                        self.remember_rejected(child, parent, again, chain,
                                               child_parent_mismatch, child_group_mismatch, parent_identity_mismatch)
                        raise Incomplete('child-chain-unstable-or-escaped')
                    ancestry = chain + [parent]
                    self.observe(child, ancestry)
                    pending.append((child, ancestry))
                except Exception as e:
                    self.run.note('process-observation-gap', reason=type(e).__name__ + ':' + str(e))

    def observe(self, child, ancestry):
        key = self.identity(child)
        if key not in self.records:
            if len(self.records) >= 4096 or len(self.watchers) >= 128:
                raise Incomplete('process-observation-budget')
            cookie = self.next_cookie
            self.next_cookie += 1
            # NOTE_EXITSTATUS=0x04000000 from Apple's public event.h. This
            # watches an already observed live process; no deprecated TRACK.
            change = select.kevent(child['pid'], filter=select.KQ_FILTER_PROC,
                                   flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                   fflags=select.KQ_NOTE_EXIT | 0x04000000, udata=cookie)
            self.queue.control([change], 0, 0)
            again = self.read(child['pid'])
            if self.identity(again) != key or again['ppid'] != child['ppid'] or again['path'] != child['path']:
                raise Incomplete('process-changed-at-exit-registration')
            self.watchers[cookie] = key
            self.records[key] = {'identity': child, 'ancestry': ancestry,
                                 'first_observed_monotonic': time.monotonic(),
                                 'first_observed_wall_ns': time.time_ns(), 'exit_observed': False}
            self.run.note('owned-descendant-observed', record=self.records[key])
        record = self.records[key]
        record['last_observed_monotonic'] = time.monotonic()
        record['last_observed_wall_ns'] = time.time_ns()
        # These are receipt clocks only; NEVER convert trace sample timestamps
        # with them or treat an interval as an established profiling clock map.

    def drain_events(self):
        for event in self.queue.control(None, 128, 0):
            key = self.watchers.pop(event.udata, None)
            if key is None or event.ident != key[0] or event.flags & select.KQ_EV_ERROR or not event.fflags & select.KQ_NOTE_EXIT:
                raise Incomplete('exit-notifier-identity-gap')
            record = self.records.get(key)
            if record is None:
                raise Incomplete('exit-without-observation')
            record['exit_observed'] = True
            record['actual_exit_status'] = event.data
            record['exit_receipt_monotonic'] = time.monotonic()
            self.run.note('observed-descendant-exit', record=record)

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.drain_events()
            except Exception as e:
                self.run.note('process-exit-observation-gap', reason=type(e).__name__ + ':' + str(e))
            finally:
                try:
                    self.run.note('process-observation-final', records=list(self.records.values()),
                                  unresolved_exit_cookies=list(self.watchers))
                finally:
                    self.queue.close()  # Release every still-registered notifier.


class Notification:
    def __init__(self, name):
        self.library = ctypes.CDLL('/usr/lib/system/libsystem_notify.dylib')
        fn = self.library.notify_register_file_descriptor
        fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int), ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        fn.restype = ctypes.c_uint32
        self.library.notify_cancel.argtypes = [ctypes.c_int]
        self.library.notify_cancel.restype = ctypes.c_uint32
        self.fd = ctypes.c_int(-1)
        self.token = ctypes.c_int(-1)
        self.closed = False
        self.release_unknown = False
        # Configure everything before registration. After successful registration
        # the constructor only returns; Run takes ownership before any next step.
        if fn(name.encode(), ctypes.byref(self.fd), 0, ctypes.byref(self.token)) != 0:
            raise Incomplete('notification-registration')

    def set_noninheritable(self):
        os.set_inheritable(self.fd.value, False)

    def wait(self, run, recorder, seconds):
        deadline = time.monotonic() + seconds
        data = b''
        while time.monotonic() < deadline:
            run.guard()
            if recorder.poll() is not None:
                raise Incomplete('recorder-not-ready')
            if select.select([self.fd.value], [], [], min(0.1, max(0, deadline - time.monotonic())))[0]:
                data += os.read(self.fd.value, 4 - len(data))
                if len(data) == 4:
                    # Apple's public implementation uses htonl(token).
                    if struct.unpack('!I', data)[0] != self.token.value:
                        raise Incomplete('foreign-notification-token')
                    return
        raise Incomplete('readiness-budget')

    def close(self):
        if not self.closed:
            # notify_cancel owns descriptor closure; never close a reused FD.
            # Keep the exact token/FD until known released. Any failed attempt is
            # sticky even if a later cleanup pass returns success.
            try:
                status = self.library.notify_cancel(self.token.value)
            except BaseException:
                self.release_unknown = True
                raise
            if status != 0:
                self.release_unknown = True
                raise Incomplete('notification-cancel')
            self.closed = True


def main():
    if sys.platform != 'darwin' or os.geteuid() == 0:
        print('{"diagnostic":"incomplete"}')
        return 1
    os.umask(0o077)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    run = None
    complete = False
    result = False
    manifest = None
    try:
        run = Run()
        head, cert = run.verify_source()
        try:
            run.prelude()
            run.profile()
            complete = False  # Actual trace/schema/child proof needs private review.
        except BaseException as e:
            # Detailed reasons only in ciphertext, never public exception text.
            run.errors.append(type(e).__name__ + ':' + str(e))
        finally:
            run.cleanup_processes()
        result, manifest = run.encrypt(cert, head, complete)
    except BaseException:
        result = False
    finally:
        if run is not None:
            run.cleanup_processes()  # Encryption/archive children too.
            for f in run.files:
                try:
                    f.close()
                except Exception:
                    result = False
            try:
                shutil.rmtree(run.root)
                if manifest is not None:
                    result = False
                    manifest['status'] = 'incomplete'
                    run.publish(manifest, result)
            except Exception:
                result = False
                for name in ('ingest-cpu.cms', 'manifest.json', '.pending.cms', '.manifest.partial'):
                    (run.out / name).unlink(missing_ok=True)
    print(json.dumps({'diagnostic': 'incomplete', 'collection_only': True}))
    return 1  # An artifact never self-certifies success or product qualification.


if __name__ == '__main__':
    sys.exit(main())
