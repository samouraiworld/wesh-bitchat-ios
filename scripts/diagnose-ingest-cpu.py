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
import stat
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


def digest(owner, path):
    h = hashlib.sha256()
    f = owner.open_owned_file(path, 'rb')
    primary_error = None
    try:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    except BaseException as error:
        primary_error = error
        raise
    finally:
        try:
            owner.close_owned_file(f)
        except BaseException:
            if primary_error is None:
                raise
            # The original read/hash failure stays primary. Close debt is sticky.
    return h.hexdigest()


# Final public output is a fixed scalar vocabulary, never exception text.
PUBLIC_PHASES = frozenset(('INITIALIZE', 'SOURCE', 'PRELUDE', 'RECORD', 'EXPORT',
                          'RECORD_METADATA', 'RECORD_READY_WAIT',
                          'RECORD_SERIAL_STAGE', 'RECORD_FINALIZE_STAGE',
                          'SEAL', 'CLEANUP', 'PUBLISH', 'FINAL', 'UNKNOWN'))
PUBLIC_DISPOSITIONS = frozenset(('PUBLISHED_INCOMPLETE', 'NOT_PUBLISHED',
                                'WITHHELD_CLEANUP_UNKNOWN', 'UNKNOWN'))
PUBLIC_FAILURES = frozenset(('NONE', 'UNSUPPORTED_HOST', 'SOURCE_BINDING', 'TOOL_SUPPORT',
                            'READINESS', 'PROCESS_RETURN', 'PROCESS_LIMIT', 'RAW_LIMIT',
                            'RAW_SYMLINK',
                            'RAW_LIMIT_LARGEST_TRACE', 'RAW_LIMIT_LARGEST_EXPORT',
                            'RAW_LIMIT_LARGEST_LOG', 'RAW_LIMIT_LARGEST_IMAGE',
                            'RAW_LIMIT_LARGEST_MANIFEST', 'RAW_LIMIT_LARGEST_OTHER',
                            'RAW_LIMIT_LARGEST_MIXED',
                            'SERIAL_CONTRACT', 'EXPORT_SCHEMA', 'SYMBOL_MATERIAL',
                            'SEALING', 'PUBLICATION_BINDING', 'CLEANUP_UNKNOWN',
                            'INTERRUPTED', 'UNKNOWN'))
PUBLIC_FAILURE_CONSTANTS = {
    'head-binding': 'SOURCE_BINDING', 'source-scope': 'SOURCE_BINDING',
    'dirty-source': 'SOURCE_BINDING', 'certificate-binding': 'SOURCE_BINDING',
    'unsupported-record-tool': 'TOOL_SUPPORT', 'unsupported-export-tool': 'TOOL_SUPPORT',
    'openssl3-unavailable': 'TOOL_SUPPORT', 'openssl3-required': 'TOOL_SUPPORT',
    'notification-registration': 'READINESS', 'recorder-not-ready': 'READINESS',
    'foreign-notification-token': 'READINESS', 'readiness-budget': 'READINESS',
    'process-failed': 'PROCESS_RETURN', 'recorder-ended-before-command': 'PROCESS_RETURN',
    'serial-failed': 'PROCESS_RETURN', 'recorder-incomplete': 'PROCESS_RETURN',
    'process-budget': 'PROCESS_LIMIT', 'capture-budget': 'PROCESS_LIMIT',
    'raw-budget': 'RAW_LIMIT', 'raw-symlink': 'RAW_SYMLINK',
    'raw-budget-largest-trace': 'RAW_LIMIT_LARGEST_TRACE',
    'raw-budget-largest-export': 'RAW_LIMIT_LARGEST_EXPORT',
    'raw-budget-largest-log': 'RAW_LIMIT_LARGEST_LOG',
    'raw-budget-largest-image': 'RAW_LIMIT_LARGEST_IMAGE',
    'raw-budget-largest-manifest': 'RAW_LIMIT_LARGEST_MANIFEST',
    'raw-budget-largest-other': 'RAW_LIMIT_LARGEST_OTHER',
    'raw-budget-largest-mixed': 'RAW_LIMIT_LARGEST_MIXED',
    'serial-case-inventory': 'SERIAL_CONTRACT', 'metric-inventory': 'SERIAL_CONTRACT',
    'unsupported-or-ambiguous-sample-schema': 'EXPORT_SCHEMA',
    'unsupported-toc': 'EXPORT_SCHEMA', 'duplicate-or-empty-XML-ID': 'EXPORT_SCHEMA',
    'ambiguous-XML-reference': 'EXPORT_SCHEMA', 'missing-XML-reference': 'EXPORT_SCHEMA',
    'cyclic-XML-provenance': 'EXPORT_SCHEMA', 'missing-original-binpath': 'SYMBOL_MATERIAL',
    'ambiguous-built-test-image': 'SYMBOL_MATERIAL', 'symbol-material-budget': 'SYMBOL_MATERIAL',
    'encryption-budget': 'SEALING', 'archive-or-encryption-failed': 'SEALING',
    'upload-allowlist': 'PUBLICATION_BINDING',
    'ciphertext-publication-binding': 'PUBLICATION_BINDING',
    'descendant-outlived-command': 'CLEANUP_UNKNOWN',
    'cleanup-not-complete': 'CLEANUP_UNKNOWN', 'notification-cancel': 'CLEANUP_UNKNOWN',
    'interrupted': 'INTERRUPTED',
}


class PublicDisposition:
    def __init__(self):
        self.phase = 'INITIALIZE'
        self.blocking_phase = None
        self.failure = 'NONE'
        self.disposition = 'NOT_PUBLISHED'
        self.cleanup_known = False
        self.cleanup_uncertain = False

    def enter(self, phase):
        self.phase = phase if type(phase) is str and phase in PUBLIC_PHASES else 'UNKNOWN'

    def observe_profile_failure(self, error):
        # Optional first-failure metadata only; cleanup authority is unchanged.
        category = 'UNKNOWN'
        if (type(error) is Incomplete and len(error.args) == 1 and
                type(error.args[0]) is str):
            category = PUBLIC_FAILURE_CONSTANTS.get(error.args[0], 'UNKNOWN')
        if self.blocking_phase is None:
            self.blocking_phase = self.phase
            self.failure = category

    def blocked(self, error):
        # Match ONLY exact known Incomplete literals. Never stringify an error,
        # classify arbitrary subclasses or expose errno/type/path/message data.
        category = 'UNKNOWN'
        if (type(error) is Incomplete and len(error.args) == 1 and
                type(error.args[0]) is str):
            category = PUBLIC_FAILURE_CONSTANTS.get(error.args[0], 'UNKNOWN')
        if self.blocking_phase is None:
            self.blocking_phase = self.phase
            self.failure = category
        if category == 'CLEANUP_UNKNOWN':
            self.uncertain_cleanup()

    def uncertain_cleanup(self):
        self.cleanup_uncertain = True  # A later successful retry cannot clear it.
        self.cleanup_known = False
        self.disposition = 'WITHHELD_CLEANUP_UNKNOWN'

    def observed_cleanup(self, known):
        if type(known) is bool and known and not self.cleanup_uncertain:
            self.cleanup_known = True
        else:
            self.uncertain_cleanup()

    def payload(self):
        if (type(self.cleanup_uncertain) is not bool or
                (self.blocking_phase is not None and type(self.blocking_phase) is not str)):
            return {'diagnostic': 'incomplete', 'collection_only': True,
                    'phase': 'UNKNOWN', 'disposition': 'UNKNOWN',
                    'failure_class': 'UNKNOWN', 'cleanup_known': False}
        phase = self.blocking_phase if self.blocking_phase is not None else self.phase
        failure = self.failure
        if self.cleanup_uncertain:
            phase, failure = 'CLEANUP', 'CLEANUP_UNKNOWN'
        valid = (type(phase) is str and phase in PUBLIC_PHASES and
                 type(self.disposition) is str and self.disposition in PUBLIC_DISPOSITIONS and
                 type(failure) is str and failure in PUBLIC_FAILURES and
                 type(self.cleanup_known) is bool)
        return {'diagnostic': 'incomplete', 'collection_only': True,
                'phase': phase if valid else 'UNKNOWN',
                'disposition': self.disposition if valid else 'UNKNOWN',
                'failure_class': failure if valid else 'UNKNOWN',
                'cleanup_known': self.cleanup_known if valid else False}


class Run:
    def __init__(self, public):
        # RAM custody precedes EVERY fallible owned-path acquisition.
        self.public = public
        self.owned_close_uncertain = False
        self.file_io_uncertain = False
        self.path_cleanup_uncertain = False
        self.files = []
        self.pending_file = None
        self.processes = []
        self.pending_process = None
        self.pending_process_name = None
        self.process_custody_uncertain = False
        self.observer_custody_uncertain = False
        self.events = []
        self.errors = []
        self.notifier = None
        self.observer = None
        self.recorder = None
        self.serial = None
        self.repo = None
        self.out = None
        self.out_created = False
        self.out_identity = None
        self.stage_name = None
        self.stage = None
        self.stage_identity = None
        self.root_name = None
        self.root = None
        self.root_identity = None
        self.raw = None
        self.plaintext_removed = False
        self.cipher_identity = None
        self.manifest_identity = None
        self.case_count = 0
        self.sequence = 0
        self.raw_largest = None
        self.binpath = None
        self.epoch = time.monotonic()

    @staticmethod
    def directory_identity(path):
        value = path.lstat()
        if (not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid() or
                stat.S_IMODE(value.st_mode) != 0o700):
            raise Incomplete('owned-directory-binding')
        return (value.st_dev, value.st_ino, value.st_uid, stat.S_IMODE(value.st_mode))

    @staticmethod
    def file_identity(path):
        value = path.lstat()
        if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.geteuid() or
                stat.S_IMODE(value.st_mode) != 0o600 or value.st_nlink != 1):
            raise Incomplete('owned-file-binding')
        return (value.st_dev, value.st_ino, value.st_uid, stat.S_IMODE(value.st_mode))

    def acquire_owned_paths(self):
        self.repo = Path.cwd().resolve()
        self.out = self.repo / '.diagnostic-upload'
        if self.out.exists() or self.out.is_symlink():
            raise Incomplete('existing-output')
        self.out.mkdir(mode=0o700)
        self.out_created = True
        self.out_identity = self.directory_identity(self.out)
        # Retain the actual returned name BEFORE Path/configuration can fail.
        self.stage_name = tempfile.mkdtemp(prefix='.ingest-cpu-stage-', dir=self.repo)
        self.stage = Path(self.stage_name)
        self.stage_identity = self.directory_identity(self.stage)
        self.root_name = tempfile.mkdtemp(prefix='ingest-cpu-', dir=os.environ['RUNNER_TEMP'])
        self.root = Path(self.root_name)
        self.root_identity = self.directory_identity(self.root)
        self.root.chmod(0o700)
        self.raw = self.root / 'raw'
        self.raw.mkdir(mode=0o700)
        self.epoch = time.monotonic()

    def note(self, kind, **values):
        self.events.append({'elapsed': time.monotonic() - self.epoch, 'kind': kind, **values})

    def size(self):
        # Symlinks never expand collection outside the owned directory.
        # Observation never replaces this scan's authoritative scalar total.
        self.raw_largest = None
        observed = None
        try:
            observed = [0, 0, 0, 0, 0, 0]  # trace, export, log, image, manifest, other
        except Exception:
            pass  # Optional RAM accounting cannot change the original scan.
        total = 0
        for p in self.root.rglob('*'):
            if p.is_symlink():
                raise Incomplete('raw-symlink')
            if p.is_file():
                amount = p.stat().st_size
                total += amount
                if observed is not None:
                    try:
                        parts = p.relative_to(self.root).parts  # Lexical only; no filesystem query.
                        if parts[:2] == ('raw', 'first-serial.trace'):
                            group = 0
                        elif (len(parts) == 2 and parts[0] == 'raw' and
                              re.fullmatch(r'[0-9]{2,}-(?:trace-toc|cpu-rows)\.stdout', parts[1])):
                            group = 1
                        elif parts == ('raw', 'built-test-image'):
                            group = 3
                        elif parts == ('raw', 'private-manifest.json'):
                            group = 4
                        elif (len(parts) == 2 and parts[0] == 'raw' and
                              parts[1].endswith(('.log', '.stdout'))):
                            group = 2
                        else:
                            group = 5
                        observed[group] += amount
                    except Exception:
                        observed = None  # Failed/unsupported accounting => generic RAW_LIMIT.
        if observed is not None:
            try:
                largest = max(observed)
                if largest > 0:
                    group = observed.index(largest) if observed.count(largest) == 1 else 6
                    self.raw_largest = (
                        'raw-budget-largest-trace', 'raw-budget-largest-export',
                        'raw-budget-largest-log', 'raw-budget-largest-image',
                        'raw-budget-largest-manifest', 'raw-budget-largest-other',
                        'raw-budget-largest-mixed'
                    )[group]
            except Exception:
                self.raw_largest = None
        return total

    def guard(self):
        if STOP:
            raise Incomplete('interrupted')
        if self.size() > RAW_LIMIT:
            raise Incomplete(self.raw_largest if self.raw_largest is not None else 'raw-budget')

    def spawn(self, args, name, env=None, stdin=None, stdout=None, scratch=False):
        if self.pending_process is not None:
            self.record_process_uncertainty()
            raise Incomplete('pending-process-registration')
        self.sequence += 1
        log = (self.root if scratch else self.raw) / f'{self.sequence:02d}-{name}.log'
        f = self.open_owned_file(log, 'wb')
        self.pending_process_name = name
        try:
            p = subprocess.Popen(args, cwd=self.repo, env=env, stdin=stdin,
                                 stdout=stdout if stdout is not None else f,
                                 stderr=f, start_new_session=True)
        except BaseException:
            self.record_process_uncertainty()
            raise  # A failed factory is not proof of an absent internal child.
        self.pending_process = p  # Actual returned object BEFORE tuple/list/note.
        try:
            self.processes.append((p, p.pid, name))
            stream = p.stdout
            if stream is not None:
                if self.pending_file is not None:
                    self.record_io_uncertainty()
                    raise Incomplete('pending-file-registration')
                self.pending_file = stream  # SAME returned PIPE before list append.
                try:
                    self.files.append(stream)
                except BaseException:
                    self.record_io_uncertainty()
                    raise  # Both pending originals retain actual custody.
                self.pending_file = None
            self.pending_process = None
            self.pending_process_name = None
            self.note('spawn', name=name, pid=p.pid, args=args)
        except BaseException:
            self.record_process_uncertainty()
            raise
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

    def record_process_uncertainty(self):
        self.process_custody_uncertain = True
        self.public.uncertain_cleanup()
        try:
            self.errors.append('cleanup-process-custody-unknown')
        except BaseException:
            pass

    def record_observer_uncertainty(self):
        self.observer_custody_uncertain = True
        self.public.uncertain_cleanup()
        try:
            self.errors.append('cleanup-observer-custody-unknown')
        except BaseException:
            pass

    def record_io_uncertainty(self):
        self.file_io_uncertain = True
        self.public.uncertain_cleanup()
        try:
            self.errors.append('cleanup-file-io-unknown')
        except BaseException:
            pass  # Sticky debt survives even failed private bookkeeping.

    def open_owned_file(self, path, mode, **options):
        if self.pending_file is not None:
            self.record_io_uncertainty()
            raise Incomplete('pending-file-registration')
        try:
            handle = path.open(mode, **options)
        except BaseException:
            self.record_io_uncertainty()
            raise
        self.pending_file = handle  # Exact returned handle BEFORE registration.
        try:
            self.files.append(handle)
        except BaseException:
            self.record_io_uncertainty()
            raise  # pending_file retains the actual handle for final cleanup.
        self.pending_file = None
        return handle

    def close_owned_file(self, handle):
        try:
            handle.close()
        except BaseException:
            self.owned_close_uncertain = True
            self.public.uncertain_cleanup()
            try:
                self.errors.append('cleanup-owned-file-close')
            except BaseException:
                pass  # Sticky debt survives even failed private bookkeeping.
            raise

    def read_text(self, path, **options):
        try:
            return path.read_text(**options)
        except BaseException:
            self.record_io_uncertainty()
            raise

    def read_bytes(self, path):
        try:
            return path.read_bytes()
        except BaseException:
            self.record_io_uncertainty()
            raise

    def write_text(self, path, data, **options):
        try:
            return path.write_text(data, **options)
        except BaseException:
            self.record_io_uncertainty()
            raise

    def copy_capture_file(self, source, target):
        try:
            return shutil.copyfile(source, target)
        except BaseException:
            self.record_io_uncertainty()
            raise

    def cleanup_owned_files(self):
        handles = self.files  # Retain originals; no fallible cleanup list clone.
        pending = self.pending_file
        pending_registered = False
        index = 0
        while index < len(handles):
            handle = handles[index]
            if handle is pending:
                pending_registered = True
            try:
                self.close_owned_file(handle)
            except BaseException as error:
                self.public.blocked(error)
            index += 1
        if pending is not None and not pending_registered:
            try:
                self.close_owned_file(pending)
            except BaseException as error:
                self.public.blocked(error)
        # Do not clear pending custody/debt after a registration failure.

    def path_cleanup_unknown(self):
        self.path_cleanup_uncertain = True
        self.public.uncertain_cleanup()
        try:
            self.errors.append('cleanup-owned-path-unknown')
        except BaseException:
            pass  # Sticky debt survives even failed private bookkeeping.

    def remove_owned_plaintext(self):
        if self.root_name is None:
            self.plaintext_removed = True  # No root was acquired.
            return
        try:
            if (self.root is None or self.root_identity is None or
                    self.directory_identity(self.root) != self.root_identity):
                raise Incomplete('owned-directory-binding')
            shutil.rmtree(self.root)
            try:
                self.root.lstat()
            except FileNotFoundError:
                self.plaintext_removed = True
            else:
                raise Incomplete('plaintext-removal-unconfirmed')
        except BaseException:
            self.path_cleanup_unknown()
            raise

    def cleanup_stage(self):
        if self.stage_name is None:
            return
        try:
            if (self.stage is None or self.stage_identity is None or
                    self.directory_identity(self.stage) != self.stage_identity):
                raise Incomplete('owned-directory-binding')
        except BaseException:
            self.path_cleanup_unknown()
            return  # Never delete an unrecognized directory.
        # Each known path is attempted independently; no recursive stranger delete.
        for name, identity in (('.pending.cms', self.cipher_identity),
                               ('ingest-cpu.cms', self.cipher_identity),
                               ('manifest.json', self.manifest_identity)):
            try:
                path = self.stage / name
                try:
                    path.lstat()
                except FileNotFoundError:
                    continue
                if identity is None or self.file_identity(path) != identity:
                    raise Incomplete('owned-file-binding')
                path.unlink()
            except BaseException:
                self.path_cleanup_unknown()
        try:
            if self.directory_identity(self.stage) != self.stage_identity:
                raise Incomplete('owned-directory-binding')
            self.stage.rmdir()  # Fails on unexpected content; never repair it.
        except BaseException:
            self.path_cleanup_unknown()

    def cleanup_is_known(self):
        cleanup_gaps = ('notify-close-', 'process-observer-close-', 'unreaped-',
                        'unresolved-group-', 'cleanup-')
        return (not self.processes and self.pending_process is None and
                not self.process_custody_uncertain and not self.observer_custody_uncertain and
                self.plaintext_removed and
                self.notifier is None and self.observer is None and
                not self.owned_close_uncertain and not self.file_io_uncertain and
                not self.path_cleanup_uncertain and self.pending_file is None and
                all(f.closed for f in self.files) and
                not any(e.startswith(cleanup_gaps) for e in self.errors))

    def command(self, args, name, seconds=60, env=None, stdout_only=False):
        # Path-valued stdout must not be contaminated by benign tool stderr.
        # Both streams are still preserved privately.
        output = None
        destination = None
        if stdout_only:
            destination = self.raw / f'{self.sequence + 1:02d}-{name}.stdout'
            output = self.open_owned_file(destination, 'wb')
        p, log = self.spawn(args, name, env=env, stdout=output)
        self.wait(p, seconds)
        if output is not None:
            self.close_owned_file(output)
        return self.read_text(destination if destination is not None else log, errors='replace')

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

    def cleanup_returned_process(self, p, pgid, name):
        # Capture SAME pipe BEFORE any group/reap can remove process metadata.
        stream = None
        try:
            stream = p.stdout
        except BaseException:
            self.record_process_uncertainty()
        # SAME original escalation/reap logic; capture failure cannot skip it.
        try:
            if p.poll() is None or self.group_exists(pgid):
                self.stop_group(p, pgid, name, orderly=(p is self.recorder))
            else:
                p.wait(timeout=2)
                self.processes = [row for row in self.processes if row[0] is not p]
        except BaseException as e:
            self.record_process_uncertainty()
            try:
                self.errors.append('cleanup-' + type(e).__name__)
            except BaseException:
                pass
        finally:
            # The original Popen owns this SAME stdout PIPE even when spawn
            # raised before encrypt obtained its local or entered its finally.
            try:
                if stream is not None and not stream.closed:
                    self.close_owned_file(stream)
            except BaseException:
                self.record_process_uncertainty()

    def cleanup_processes(self):
        # Retain original containers/objects without a fallible list clone.
        registered = self.processes
        pending = self.pending_process
        pending_name = self.pending_process_name
        index = len(registered) - 1
        pending_registered = False
        while index >= 0:
            p, pgid, name = registered[index]
            if p is pending:
                pending_registered = True
            self.cleanup_returned_process(p, pgid, name)
            index -= 1
        if pending is not None and not pending_registered:
            self.cleanup_returned_process(pending, pending.pid, pending_name)
        # Failed registration debt/pending custody is never erased by a reap.
        if self.notifier is not None:
            try:
                self.notifier.close()
            except BaseException as e:
                self.public.uncertain_cleanup()
                try:
                    self.errors.append('notify-close-' + type(e).__name__)
                except BaseException:
                    pass
            if self.notifier.closed and not self.notifier.release_unknown:
                self.notifier = None
        if self.observer is not None:
            try:
                self.observer.close()
            except BaseException as e:
                self.record_observer_uncertainty()
                try:
                    self.errors.append('process-observer-close-' + type(e).__name__)
                except BaseException:
                    pass
            # Logical closed is NOT authority for actual kqueue release.
            if (self.observer.queue_close_returned and not self.observer.release_unknown and
                    not self.observer_custody_uncertain):
                self.observer = None
        for f in self.files:
            if not f.closed:
                try:
                    f.flush()
                except BaseException as e:
                    try:
                        self.errors.append('flush-' + type(e).__name__)
                    except BaseException:
                        self.record_io_uncertainty()
        try:
            self.note('all-owned-process-cleanup-attempted', errors=list(self.errors))
        except BaseException:
            self.record_process_uncertainty()

    def verify_source(self):
        actual = self.command(['git', 'rev-parse', 'HEAD'], 'head').strip()
        if actual != os.environ.get('DIAGNOSTIC_HEAD') or not re.fullmatch('[0-9a-f]{40}', actual):
            raise Incomplete('head-binding')
        changes = self.command(['git', 'diff', '--name-status', BASE, actual], 'source-diff')
        rows = [line.split('\t') for line in changes.splitlines()]
        expected = {('A', path) for path in ADDITIONS} | {
            ('M', 'bitchatTests/Services/NostrOutboundOwnerTests.swift'),
            ('M', 'bitchatTests/Services/PanicAsyncEraseActionTests.swift')
        }
        if len(rows) != 5 or {tuple(row) for row in rows} != expected:
            raise Incomplete('source-scope')
        if self.command(['git', 'status', '--porcelain', '--untracked-files=no'], 'tracked-clean').strip():
            raise Incomplete('dirty-source')
        cert = self.repo / '.github/diagnostics/ingest-cpu-recipient.pem'
        if digest(self, cert) != CERT_SHA or b'PRIVATE KEY' in self.read_bytes(cert):
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
        if len(catalogs) != 1 or self.read_bytes(catalogs[0]) != self.read_bytes(catalog) or catalogs[0].parent not in (bundle, bundle / 'Contents/Resources'):
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
        try:
            self.public.enter('RECORD_METADATA')
        except BaseException:
            pass
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
        try:
            self.public.enter('RECORD_READY_WAIT')
        except BaseException:
            pass
        self.notifier.wait(self, self.recorder, seconds=30)
        try:
            self.public.enter('RECORD_SERIAL_STAGE')
        except BaseException:
            pass
        env = dict(os.environ, BITCHAT_PERF_LOG=str(self.raw / 'perf-output.log'))
        # FIRST and ONLY serial command, including coverage→noncoverage build.
        self.serial, serial_log = self.spawn(['swift', 'test', '--quiet', '--filter', 'PerformanceBaselineTests'],
                                             'first-serial', env=env)
        serial_start = time.monotonic()
        try:
            self.observer = ProcessObservation(self, self.serial)
            self.note('serial-process-identity', identity=self.observer.root_identity)
        except BaseException as e:
            self.record_observer_uncertainty()
            try:
                self.note('process-observer-unavailable', reason=type(e).__name__ + ':' + str(e))
            except BaseException:
                pass
            raise  # Stop new collection; no failed factory means known absence.
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
        try:
            self.public.enter('RECORD_FINALIZE_STAGE')
        except BaseException:
            pass
        self.note('recorder-natural-finalization', absolute_deadline=trace_start - self.epoch + TRACE_SECONDS + TRACE_FINALIZE_SECONDS)
        self.wait(self.recorder, TRACE_SECONDS + TRACE_FINALIZE_SECONDS, started_at=trace_start)
        if self.errors or self.recorder.returncode != 0:
            raise Incomplete('recorder-incomplete')
        self.notifier.close()
        if not self.notifier.release_unknown:
            self.notifier = None
        text = self.read_text(serial_log, errors='replace')
        rows = re.findall(r"Test Case '([^']+)' passed \(", text)
        expected = re.findall(r'func (test\w+)\(', self.read_text(self.repo / 'bitchatTests/Performance/PerformanceBaselineTests.swift'))
        actual = [x.rsplit(' ', 1)[-1].rstrip(']') for x in rows]
        if len(expected) != 11 or len(rows) != 11 or sorted(actual) != sorted(expected):
            raise Incomplete('serial-case-inventory')
        self.case_count = len(rows)
        metrics = re.findall(r'PERF\[([^\]]+)\]:\s*([0-9.]+)\s*(\S+)/sec', text)
        floors = json.loads(self.read_text(self.repo / 'bitchatTests/Performance/perf-floors.json'))['floors']
        if len(metrics) != 10 or {x[0] for x in metrics} != set(floors):
            raise Incomplete('metric-inventory')
        # Values are preserved, NEVER evaluated as qualification or selected.
        self.note('serial-inventory', cases=rows, measurements=metrics)
        self.export_samples(trace)

    def export_samples(self, trace):
        self.public.enter('EXPORT')
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
        self.note('built-image-unverified', image=str(binary), sha256=digest(self, binary), uuid_output=uuid_text)
        if binary.stat().st_size > RAW_LIMIT // 2 or self.size() + binary.stat().st_size > RAW_LIMIT:
            raise Incomplete('symbol-material-budget')
        self.copy_capture_file(binary, self.raw / 'built-test-image')
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
        self.write_text(self.raw / 'private-manifest.json', json.dumps({'head': head, 'complete': complete,
                       'events': self.events, 'errors': self.errors}, indent=2))
        self.guard()
        for f in self.files:
            self.close_owned_file(f)
        partial = self.root / 'ciphertext.partial'
        self.verify_empty_stage()
        staged = self.stage / '.pending.cms'  # Outside workflow upload paths.
        pipe, _ = self.spawn(['/usr/bin/tar', '-czf', '-', '-C', str(self.root), 'raw'],
                             'archive', stdout=subprocess.PIPE, scratch=True)
        primary_error = None
        try:
            enc, _ = self.spawn([str(openssl), 'cms', '-encrypt', '-binary', '-stream', '-outform', 'DER',
                                 '-aes-256-gcm', '-recip', str(cert), '-keyopt', 'rsa_padding_mode:oaep',
                                 '-keyopt', 'rsa_oaep_md:sha256', '-keyopt', 'rsa_mgf1_md:sha256',
                                 '-out', str(partial)], 'encrypt', stdin=pipe.stdout, scratch=True)
            self.close_owned_file(pipe.stdout)
            deadline = time.monotonic() + 120
            while enc.poll() is None or pipe.poll() is None:
                if STOP or time.monotonic() > deadline or (partial.exists() and partial.stat().st_size > CIPHER_LIMIT):
                    raise Incomplete('encryption-budget')
                time.sleep(0.1)
            if pipe.returncode != 0 or enc.returncode != 0 or not partial.is_file() or not 0 < partial.stat().st_size <= CIPHER_LIMIT:
                raise Incomplete('archive-or-encryption-failed')
            os.replace(partial, staged)
            self.cipher_identity = self.file_identity(staged)
            manifest = {'source_commit': head, 'kind': 'diagnostic-only-never-qualification',
                        'status': 'incomplete', 'ciphertext_sha256': digest(self, staged),
                        'ciphertext_bytes': staged.stat().st_size, 'certificate_sha256': CERT_SHA,
                        'sample_ownership_verified': False, 'serial_case_count': self.case_count}
            return False, manifest
        except BaseException as error:
            primary_error = error
            raise
        finally:
            if pipe.stdout is not None:
                try:
                    self.close_owned_file(pipe.stdout)
                except BaseException:
                    if primary_error is None:
                        raise
                    # Keep the first actual failure primary; the independent
                    # close failure is sticky cleanup debt, never completion.

    def directory_entries(self, path):
        try:
            return {p.name for p in path.iterdir()}
        except BaseException:
            self.path_cleanup_unknown()
            raise

    def verify_empty_stage(self):
        if (self.stage is None or self.stage_identity is None or
                self.directory_identity(self.stage) != self.stage_identity or
                self.stage.parent != self.repo or self.directory_entries(self.stage)):
            raise Incomplete('upload-allowlist')

    def prepare_closed_pair(self, manifest):
        # All actual recorded processes/streams/plaintext are already retired.
        if not self.cleanup_is_known():
            raise Incomplete('cleanup-not-complete')
        if (self.stage is None or self.stage_identity is None or
                self.directory_identity(self.stage) != self.stage_identity or
                self.stage.parent != self.repo or
                self.directory_entries(self.stage) != {'.pending.cms'}):
            raise Incomplete('upload-allowlist')
        expected_keys = {'source_commit', 'kind', 'status', 'ciphertext_sha256',
                         'ciphertext_bytes', 'certificate_sha256',
                         'sample_ownership_verified', 'serial_case_count'}
        if (type(manifest) is not dict or set(manifest) != expected_keys or
                type(manifest['source_commit']) is not str or
                not re.fullmatch('[0-9a-f]{40}', manifest['source_commit']) or
                manifest['kind'] != 'diagnostic-only-never-qualification' or
                manifest['status'] != 'incomplete' or
                type(manifest['ciphertext_sha256']) is not str or
                not re.fullmatch('[0-9a-f]{64}', manifest['ciphertext_sha256']) or
                type(manifest['ciphertext_bytes']) is not int or
                not 0 < manifest['ciphertext_bytes'] <= CIPHER_LIMIT or
                manifest['certificate_sha256'] != CERT_SHA or
                manifest['sample_ownership_verified'] is not False or
                type(manifest['serial_case_count']) is not int or
                manifest['serial_case_count'] not in (0, 11)):
            raise Incomplete('ciphertext-publication-binding')
        staged = self.stage / '.pending.cms'
        if (self.cipher_identity is None or self.file_identity(staged) != self.cipher_identity or
                digest(self, staged) != manifest['ciphertext_sha256'] or
                staged.stat().st_size != manifest['ciphertext_bytes']):
            raise Incomplete('ciphertext-publication-binding')
        os.replace(staged, self.stage / 'ingest-cpu.cms')
        expected = (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode('ascii')
        if len(expected) > 4096:
            raise Incomplete('ciphertext-publication-binding')
        target = self.stage / 'manifest.json'
        handle = self.open_owned_file(target, 'xb')
        primary_error = None
        try:
            value = os.fstat(handle.fileno())
            self.manifest_identity = (value.st_dev, value.st_ino, value.st_uid,
                                      stat.S_IMODE(value.st_mode))
            if handle.write(expected) != len(expected):
                raise Incomplete('ciphertext-publication-binding')
        except BaseException as error:
            primary_error = error
            raise
        finally:
            try:
                self.close_owned_file(handle)
            except BaseException:
                if primary_error is None:
                    raise
        reader = self.open_owned_file(target, 'rb')
        primary_error = None
        try:
            if reader.read(4097) != expected:
                raise Incomplete('ciphertext-publication-binding')
        except BaseException as error:
            primary_error = error
            raise
        finally:
            try:
                self.close_owned_file(reader)
            except BaseException:
                if primary_error is None:
                    raise
        if (self.file_identity(self.stage / 'ingest-cpu.cms') != self.cipher_identity or
                self.file_identity(target) != self.manifest_identity or
                self.directory_entries(self.stage) != {'ingest-cpu.cms', 'manifest.json'}):
            raise Incomplete('upload-allowlist')
        if (not self.out_created or self.out_identity is None or self.out.parent != self.repo or
                self.directory_identity(self.out) != self.out_identity or self.directory_entries(self.out) or
                self.directory_identity(self.stage) != self.stage_identity or
                self.out_identity[0] != self.stage_identity[0]):
            raise Incomplete('upload-allowlist')
        if not self.cleanup_is_known():
            raise Incomplete('cleanup-not-complete')
        if STOP:
            raise Incomplete('interrupted')
        # No file access is permitted after the following terminal commit call.
        return os.fspath(self.stage), os.fspath(self.out)


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
        self.release_unknown = False
        self.queue_close_returned = False
        self.queue = None
        self.queue = select.kqueue()  # FINAL acquisition/action; Run owns next.

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
            self.closed = True  # Logical entry only, never a release witness.
            primary_error = None
            try:
                try:
                    self.drain_events()
                except Exception as e:
                    self.run.note('process-exit-observation-gap', reason=type(e).__name__ + ':' + str(e))
            except BaseException as error:
                primary_error = error
            finally:
                try:
                    self.run.note('process-observation-final', records=list(self.records.values()),
                                  unresolved_exit_cookies=list(self.watchers))
                except BaseException as error:
                    if primary_error is None:
                        primary_error = error
                finally:
                    try:
                        self.queue.close()  # SAME actual kqueue; no extra drain/retry.
                    except BaseException as error:
                        self.release_unknown = True
                        if primary_error is None:
                            primary_error = error
                    else:
                        self.queue_close_returned = True
            if primary_error is not None:
                raise primary_error


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
    public = PublicDisposition()
    if sys.platform != 'darwin' or os.geteuid() == 0:
        public.failure = 'UNSUPPORTED_HOST'
        return json.dumps(public.payload())
    os.umask(0o077)
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    run = None
    complete = False
    result = False
    manifest = None
    try:
        run = Run(public)
        try:
            run.acquire_owned_paths()  # The original Run already has main custody.
        except BaseException:
            run.path_cleanup_unknown()  # A failed factory is not known absence.
            raise
        public.enter('SOURCE')
        head, cert = run.verify_source()
        try:
            public.enter('PRELUDE')
            run.prelude()
            public.enter('RECORD')
            run.profile()
            complete = False  # Actual trace/schema/child proof needs private review.
        except BaseException as e:
            try:
                public.observe_profile_failure(e)
            except BaseException:
                pass  # Optional observation cannot skip original error handling.
            # Detailed reasons only in ciphertext, never public exception text.
            run.errors.append(type(e).__name__ + ':' + str(e))
        finally:
            public.enter('CLEANUP')
            run.cleanup_processes()
        public.enter('SEAL')
        result, manifest = run.encrypt(cert, head, complete)
    except BaseException as error:
        public.blocked(error)
        result = False
    finally:
        if run is not None:
            public.enter('CLEANUP')
            try:
                run.cleanup_processes()  # Encryption/archive children too.
            except BaseException as error:
                public.blocked(error)
                public.uncertain_cleanup()
            try:
                run.cleanup_owned_files()
            except BaseException as error:
                public.blocked(error)
                public.uncertain_cleanup()
            try:
                run.remove_owned_plaintext()
            except BaseException as error:
                public.blocked(error)
                public.uncertain_cleanup()
    # ALL cleanup finally blocks are over before either pair preparation or commit.
    try:
        if run is None:
            return json.dumps(public.payload())
        if manifest is None or not run.cleanup_is_known() or public.cleanup_uncertain:
            run.cleanup_stage()
            public.observed_cleanup(run.cleanup_is_known())
            return json.dumps(public.payload())
        public.enter('PUBLISH')
        source, destination = run.prepare_closed_pair(manifest)
        public.observed_cleanup(run.cleanup_is_known())
        if not public.cleanup_known or public.cleanup_uncertain:
            raise Incomplete('cleanup-not-complete')
        # Both outputs are prepared BEFORE the one terminal namespace operation.
        published = json.dumps({'diagnostic': 'incomplete', 'collection_only': True,
                                'phase': 'FINAL', 'disposition': 'PUBLISHED_INCOMPLETE',
                                'failure_class': 'NONE', 'cleanup_known': True})
        unknown = json.dumps({'diagnostic': 'incomplete', 'collection_only': True,
                              'phase': 'UNKNOWN', 'disposition': 'UNKNOWN',
                              'failure_class': 'UNKNOWN', 'cleanup_known': True})
    except BaseException as error:
        public.blocked(error)
        if run is not None:
            try:
                run.cleanup_owned_files()  # Includes new validation/pair handles.
            except BaseException as cleanup_error:
                public.blocked(cleanup_error)
                public.uncertain_cleanup()
            try:
                run.cleanup_stage()
            except BaseException as cleanup_error:
                public.blocked(cleanup_error)
                public.uncertain_cleanup()
            try:
                public.observed_cleanup(run.cleanup_is_known())
            except BaseException as cleanup_error:
                public.blocked(cleanup_error)
                public.uncertain_cleanup()
        return json.dumps(public.payload())
    # Terminal commit: outside EVERY cleanup/finally. On EIO/unknown outcome,
    # ONLY a prevalidated closed encrypted pair may be exposed. No post-call I/O.
    try:
        os.replace(source, destination)
    except BaseException:
        return unknown
    return published


if __name__ == '__main__':
    try:
        payload = main()
    except BaseException:
        # An unexpected path gets no exception text, success or release claim.
        payload = '{"diagnostic": "incomplete", "collection_only": true, "phase": "UNKNOWN", "disposition": "UNKNOWN", "failure_class": "UNKNOWN", "cleanup_known": false}'
    try:
        print(payload)  # Exactly one already-encoded fixed-object output attempt.
    except BaseException:
        pass  # A failed stdout never licenses an exception-text fallback.
    sys.exit(1)  # Always incomplete; no artifact qualifies the product.
