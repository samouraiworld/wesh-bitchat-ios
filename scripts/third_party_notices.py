#!/usr/bin/env python3
"""Generate/check offline notices from locked Cargo archives and pinned primary texts.

Generation consumes Cargo metadata obtained separately with --offline --locked for
all five Apple targets. It never invokes Cargo, compilers, or the network.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile
import tomllib

RESOURCE = Path('bitchat/Views/Wesh/Pave/Notices')
INVENTORY = RESOURCE / 'NoticeInventory.json'
ARTI_TEXT = RESOURCE / 'Arti-NOTICES.txt'
SECP_TEXT = RESOURCE / 'secp256k1-NOTICES.txt'
PRIMARY = Path('scripts/notices/primary')
SUPPLEMENTS = Path('scripts/notices/supplements.json')
LOCK = Path('localPackages/Arti/Cargo.lock')
MANIFEST = Path('localPackages/Arti/arti-bitchat/Cargo.toml')
TARGETS = {'aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios',
           'aarch64-apple-darwin', 'x86_64-apple-darwin'}
SCOPE = ('Cargo normal-dependency closure of arti-bitchat for the five packaged Apple targets, '
         'with resolved default features; build/dev edges and proc-macro targets excluded. '
         'This conservative source inventory can include code removed by release optimization. '
         'It does not certify binary provenance or complete source-distribution obligations.')
SUPPORTED_LICENSES = {'MIT', 'Apache-2.0', 'BSD-3-Clause', 'Unlicense', 'Unicode-3.0',
                      'Zlib', 'ISC', '0BSD', 'BSD-2-Clause', 'CC0-1.0', 'MPL-2.0',
                      'LGPL-3.0-or-later'}
LICENSE_NAME = re.compile(r'^(licen[sc]e|copying|notice|copyright|mit[.-]|apache[.-]|mpl[.-]|lgpl[.-]|bsd[.-]|isc[.-]|zlib[.-]|unlicense)', re.I)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def key(package):
    return package['name'] + '@' + package['version']


def select(metadata):
    packages = {p['id']: p for p in metadata['packages']}
    nodes = {n['id']: n for n in metadata['resolve']['nodes']}
    pending = [p['id'] for p in packages.values() if p['name'] == 'arti-bitchat']
    if len(pending) != 1:
        raise ValueError('metadata must have one arti-bitchat root')
    selected = {}
    while pending:
        identity = pending.pop()
        if identity in selected:
            continue
        selected[identity] = packages[identity]
        for dep in nodes[identity]['deps']:
            package = packages[dep['pkg']]
            if (any(k['kind'] is None for k in dep['dep_kinds'])
                    and not any('proc-macro' in t['kind'] for t in package['targets'])):
                pending.append(dep['pkg'])
    return [p for p in selected.values() if p['source'] is not None]


def notice_name(path):
    parts = Path(path).parts
    return bool(LICENSE_NAME.match(parts[-1]) or any(p.lower() == 'licenses' for p in parts[:-1]))


def archive_notices(package, checksum, cache, source_matches):
    filename = f"{package['name']}-{package['version']}.crate"
    matches = list(cache.glob('*/' + filename))
    if len(matches) != 1:
        raise ValueError('missing or ambiguous cached archive: ' + filename)
    archive = matches[0]
    if digest(archive.read_bytes()) != checksum:
        raise ValueError('archive checksum mismatch: ' + filename)
    texts, vcs = [], {}
    with tarfile.open(archive, 'r:gz') as tar:
        for path, sha in source_matches.items():
            member = tar.getmember(f"{package['name']}-{package['version']}/{path}")
            if digest(tar.extractfile(member).read()) != sha:
                raise ValueError('release source does not match locked archive: ' + path)
        manifest = tomllib.loads(tar.extractfile(f"{package['name']}-{package['version']}/Cargo.toml").read().decode())['package']
        if (manifest['name'], manifest['version'], manifest.get('license')) != (package['name'], package['version'], package['license']):
            raise ValueError('metadata does not match locked archive manifest')
        for member in tar.getmembers():
            if not member.isfile():
                continue
            path = '/'.join(Path(member.name).parts[1:])
            if path == '.cargo_vcs_info.json':
                vcs = json.loads(tar.extractfile(member).read())
            if notice_name(path) or path == package.get('license_file'):
                data = tar.extractfile(member).read()
                texts.append((path, data, 'https://static.crates.io/crates/' + package['name'] + '/' + filename + '#' + member.name))
        # This crate places its copyright and dual-license notice in the source header.
        if package['name'] == 'priority-queue':
            raw = tar.extractfile(f"{package['name']}-{package['version']}/src/lib.rs").read()
            header = raw[:raw.index(b'*/') + 2]
            texts.append(('src/lib.rs (opening copyright/license comment)', header,
                          package['repository'] + '/blob/' + vcs['git']['sha1'] + '/src/lib.rs'))
    return texts, vcs


def generate(root, metadata_paths, cache):
    lock = tomllib.loads((root / LOCK).read_text())
    locked = {key(p): p for p in lock['package'] if p.get('source')}
    packages, platforms = {}, {}
    for target, path in metadata_paths.items():
        chosen = select(json.loads(path.read_text()))
        platforms[target] = sorted(key(p) for p in chosen)
        for package in chosen:
            packages[key(package)] = package
    if set(platforms) != TARGETS:
        raise ValueError('metadata required for exactly the five packaged Apple targets')
    supplements = json.loads((root / SUPPLEMENTS).read_text())
    blobs, components, unresolved, qualifications = {}, [], [], []
    for identity, package in sorted(packages.items()):
        pin = locked.get(identity)
        if not pin or pin['source'] != package['source']:
            raise ValueError('metadata is not in Cargo.lock: ' + identity)
        supplement = supplements.get(identity)
        expression = package.get('license') or ''
        terms = set(re.findall(r'[A-Za-z0-9][A-Za-z0-9.+-]*', expression)) - {'OR', 'AND'}
        if not terms or not terms <= SUPPORTED_LICENSES:
            raise ValueError('unknown license expression requires review: ' + identity)
        texts, vcs = archive_notices(package, pin['checksum'], cache, (supplement or {}).get('archiveMatches', {}))
        if supplement:
            if vcs.get('git', {}).get('sha1') != supplement.get('revision'):
                raise ValueError('supplement revision mismatch: ' + identity)
            for evidence in supplement.get('scopeEvidence', []):
                if digest((root / PRIMARY / evidence['file']).read_bytes()) != evidence['sha256']:
                    raise ValueError('scope evidence hash mismatch: ' + identity)
            for notice in supplement['notices']:
                data = (root / PRIMARY / notice['file']).read_bytes()
                if digest(data) != notice['sha256']:
                    raise ValueError('primary text hash mismatch: ' + identity)
                if notice.get('startAt'):
                    data = data[data.index(notice['startAt'].encode()):]
                texts.append((notice['path'], data, notice['url']))
        records = []
        for path, data, url in texts:
            if not data.strip():
                raise ValueError('empty primary notice: ' + identity)
            data.decode('utf-8')
            sha = digest(data)
            blobs[sha] = data
            records.append({'path': path, 'url': url, 'sha256': sha})
        if not records or (supplement and supplement.get('unresolved')):
            unresolved.append(identity + ': ' + (supplement or {}).get('unresolved', 'full primary license text missing'))
        if supplement and supplement.get('qualification'):
            qualifications.append(identity + ': ' + supplement['qualification'])
        components.append({'name': package['name'], 'version': package['version'],
                           'license': package['license'], 'sourceURL': package['repository'] or ('https://crates.io/crates/' + package['name'] + '/' + package['version']),
                           'sourceArchiveURL': 'https://static.crates.io/crates/' + package['name'] + '/' + package['name'] + '-' + package['version'] + '.crate',
                           'crateChecksum': pin['checksum'], 'revision': vcs.get('git', {}).get('sha1'),
                           'notices': sorted(records, key=lambda r: (r['path'], r['url'])),
                           'supplementEvidence': (supplement or {}).get('scopeEvidence', []),
                           'releaseCommit': (supplement or {}).get('releaseCommit')})
    sections = ['Arti and native dependency notices\n\n' + SCOPE + '\n']
    if unresolved:
        sections.append('\nINCOMPLETE INVENTORY — missing primary material:\n' + '\n'.join(unresolved) + '\n')
    if qualifications:
        sections.append('\nSource qualifications pending review:\n' + '\n'.join(qualifications) + '\n')
    for component in components:
        sections.append('\n' + key(component) + '\nLicense expression: ' + str(component['license'])
                        + '\nSource: ' + str(component['sourceURL']) + '\nLocked source archive: ' + component['sourceArchiveURL'] + '\n')
        for notice in component['notices']:
            sections.append(notice['path'] + '\n' + notice['url'] + '\nText SHA-256: ' + notice['sha256'] + '\n')
    for sha, data in sorted(blobs.items()):
        sections.append('\n===== BEGIN PRIMARY TEXT ' + sha + ' =====\n' + data.decode('utf-8')
                        + '\n===== END PRIMARY TEXT ' + sha + ' =====\n')
    arti = ''.join(sections).encode()
    (root / RESOURCE).mkdir(parents=True, exist_ok=True)
    (root / ARTI_TEXT).write_bytes(arti)
    inventory = {'schemaVersion': 1, 'scope': SCOPE, 'unresolved': unresolved, 'qualifications': qualifications,
                 'cargoLockSHA256': digest((root / LOCK).read_bytes()),
                 'cargoManifestSHA256': digest((root / MANIFEST).read_bytes()),
                 'targets': platforms, 'components': components,
                 'componentsSHA256': digest(json_bytes(components)),
                 'artifacts': {str(ARTI_TEXT): digest(arti),
                               str(SECP_TEXT): digest((root / SECP_TEXT).read_bytes())}}
    (root / INVENTORY).write_bytes(json_bytes(inventory))
    return unresolved


def check(root):
    inventory = json.loads((root / INVENTORY).read_text())
    if digest((root / LOCK).read_bytes()) != inventory['cargoLockSHA256']:
        raise ValueError('Cargo.lock changed; regenerate inventory')
    if digest((root / MANIFEST).read_bytes()) != inventory['cargoManifestSHA256']:
        raise ValueError('Cargo manifest changed; regenerate inventory')
    if inventory.get('schemaVersion') != 1 or set(inventory['artifacts']) != {str(ARTI_TEXT), str(SECP_TEXT)}:
        raise ValueError('incomplete artifact inventory')
    components = inventory['components']
    if digest(json_bytes(components)) != inventory['componentsSHA256']:
        raise ValueError('component inventory hash mismatch')
    if set(inventory['targets']) != TARGETS:
        raise ValueError('incomplete target inventory')
    expected = set().union(*(set(v) for v in inventory['targets'].values()))
    if expected != {key(p) for p in components} or len(expected) != len(components):
        raise ValueError('missing or duplicate component inventory entry')
    locked = {key(p): p for p in tomllib.loads((root / LOCK).read_text())['package'] if p.get('source')}
    arti = (root / ARTI_TEXT).read_bytes()
    for component in components:
        if locked[key(component)]['checksum'] != component['crateChecksum'] or not component['notices']:
            raise ValueError('invalid locked component: ' + key(component))
        for notice in component['notices']:
            sha = notice['sha256']
            start = ('\n===== BEGIN PRIMARY TEXT ' + sha + ' =====\n').encode()
            end = ('\n===== END PRIMARY TEXT ' + sha + ' =====\n').encode()
            try:
                text = arti.split(start, 1)[1].split(end, 1)[0]
            except IndexError:
                raise ValueError('missing primary text: ' + key(component)) from None
            if digest(text) != sha:
                raise ValueError('primary text hash mismatch: ' + key(component))
    for name, sha in inventory['artifacts'].items():
        if digest((root / name).read_bytes()) != sha:
            raise ValueError('artifact text hash mismatch: ' + name)
    secp = (root / SECP_TEXT).read_text()
    if '0a1a9f9031b6f86f92eb9b66ef8a6882af531e6f' not in (root / 'Package.swift').read_text():
        raise ValueError('secp package pin changed; refresh notices')
    for marker in ['Copyright (c) 2020 GigaBitcoin LLC', 'Copyright (c) 2013 Pieter Wuille',
                   '70f149b9a1bf4ed3266f97774d0ae9577534bf40']:
        if marker not in secp:
            raise ValueError('missing secp notice: ' + marker)

    if inventory.get('unresolved'):
        raise ValueError('unresolved primary material: ' + '; '.join(inventory['unresolved']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'generate'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--metadata', action='append', default=[], metavar='TARGET=JSON')
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cargo/registry/cache')
    args = parser.parse_args()
    try:
        if args.command == 'generate':
            inputs = {target: Path(path) for target, path in (a.split('=', 1) for a in args.metadata)}
            missing = generate(args.root, inputs, args.cache)
            if missing:
                raise ValueError('unresolved primary material: ' + '; '.join(missing))
        check(args.root)
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        parser.exit(1, str(error) + '\n')
    print('Offline notice inventory matches pinned sources and bundled texts.')


if __name__ == '__main__':
    main()
