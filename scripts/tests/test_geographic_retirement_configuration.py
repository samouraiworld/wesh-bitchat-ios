"""Read-only source configuration contracts for geographic graph retirement.

These check semantic plist/project resource membership. They do not establish
what a compiled app links or bundles; final iOS/macOS artifacts need inspection.
"""
import json
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOKEN = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', re.S)


def parse_openstep(source):
    tokens = [match.group() for match in TOKEN.finditer(source)
              if not match.group().isspace() and not match.group().startswith(('/*', '//'))]
    index = 0

    def take(expected=None):
        nonlocal index
        if index == len(tokens):
            raise ValueError('Unexpected end of OpenStep plist')
        token = tokens[index]
        index += 1
        if expected is not None and token != expected:
            raise ValueError(f'Expected {expected}, found {token}')
        return token

    def value():
        if index == len(tokens):
            raise ValueError('Missing OpenStep value')
        if tokens[index] == '{':
            take('{')
            result = {}
            while index < len(tokens) and tokens[index] != '}':
                key = atom(take())
                take('=')
                if key in result:
                    raise ValueError(f'Duplicate OpenStep key {key}')
                result[key] = value()
                take(';')
            take('}')
            return result
        if tokens[index] == '(':
            take('(')
            result = []
            while index < len(tokens) and tokens[index] != ')':
                result.append(value())
                if index < len(tokens) and tokens[index] == ',':
                    take(',')
                elif index < len(tokens) and tokens[index] != ')':
                    raise ValueError('Missing OpenStep list separator')
            take(')')
            return result
        return atom(take())

    def atom(token):
        if token in '{}()=;,':
            raise ValueError(f'Unexpected OpenStep punctuation {token}')
        return json.loads(token) if token.startswith('"') else token

    result = value()
    if index != len(tokens):
        raise ValueError('Trailing OpenStep plist content')
    return result


def load_plist(relative):
    with (ROOT / relative).open('rb') as source:
        return plistlib.load(source)


def application_resource_memberships(root, project):
    """Resolve explicit build refs and relevant synchronized-folder resources."""
    objects = project['objects']
    result = {}
    for target_id, target in objects.items():
        if target.get('isa') != 'PBXNativeTarget' or target.get('productType') != 'com.apple.product-type.application':
            continue
        resources = set()
        for phase_id in target.get('buildPhases', []):
            phase = objects[phase_id]
            if phase.get('isa') != 'PBXResourcesBuildPhase':
                continue
            for build_id in phase.get('files', []):
                build = objects[build_id]
                reference = objects[build['fileRef']]
                resources.add(reference.get('path', reference.get('name')))
        for group_id in target.get('fileSystemSynchronizedGroups', []):
            group = objects[group_id]
            if group.get('isa') != 'PBXFileSystemSynchronizedRootGroup':
                continue
            excluded = set()
            for exception_id in group.get('exceptions', []):
                exception = objects[exception_id]
                if exception.get('target') == target_id:
                    excluded.update(exception.get('membershipExceptions', []))
            folder = root / group['path']
            # Swift/asset compilation is outside this source-resource contract.
            # Documents, CSV and fonts are resources unless explicitly excluded.
            for source in folder.rglob('*'):
                if source.is_file() and source.suffix.lower() in {'.md', '.csv', '.txt', '.ttf'}:
                    relative = source.relative_to(folder).as_posix()
                    if relative not in excluded:
                        resources.add(source.relative_to(root).as_posix())
        result[target['name']] = resources
    return result


class GeographicRetirementConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.info = load_plist('bitchat/Info.plist')
        cls.entitlements = load_plist('bitchat/bitchat-macOS.entitlements')
        cls.project = parse_openstep((ROOT / 'bitchat.xcodeproj/project.pbxproj').read_text())
        cls.resources = application_resource_memberships(ROOT, cls.project)

    def assert_no_location_permission(self, values):
        self.assertEqual([key for key in values if key.startswith('NSLocation')], [])

    def test_app_info_does_not_declare_location_permission(self):
        self.assert_no_location_permission(self.info)

    def test_english_usage_strings_do_not_declare_location_permission(self):
        values = parse_openstep('{' + (ROOT / 'bitchat/en.lproj/InfoPlist.strings').read_text() + '}')
        self.assert_no_location_permission(values)

    def test_french_usage_strings_do_not_declare_location_permission(self):
        values = parse_openstep('{' + (ROOT / 'bitchat/fr.lproj/InfoPlist.strings').read_text() + '}')
        self.assert_no_location_permission(values)

    def test_mac_app_has_no_location_entitlement(self):
        self.assertNotIn('com.apple.security.personal-information.location', self.entitlements)

    def test_neither_app_target_bundles_geographic_relay_csv(self):
        self.assertEqual(set(self.resources), {'bitchat_iOS', 'bitchat_macOS'})
        leaks = {target: sorted(path for path in paths if Path(path).suffix.lower() == '.csv')
                 for target, paths in self.resources.items()}
        self.assertEqual(leaks, {'bitchat_iOS': [], 'bitchat_macOS': []})

    def test_neither_app_target_bundles_internal_readme(self):
        self.assertEqual(set(self.resources), {'bitchat_iOS', 'bitchat_macOS'})
        leaks = {target: sorted(path for path in paths if Path(path).name.lower() == 'readme.md')
                 for target, paths in self.resources.items()}
        self.assertEqual(leaks, {'bitchat_iOS': [], 'bitchat_macOS': []})

    def test_retired_geographic_download_workflows_cannot_recreate_the_csv(self):
        owners = ['.github/workflows/fetch_georelays.yml', '.github/workflows/validate_georelays.yml']
        self.assertEqual([path for path in owners if (ROOT / path).exists()], [])

    def test_wesh_scheme_bluetooth_camera_and_background_ble_are_preserved(self):
        self.assertEqual([scheme for entry in self.info['CFBundleURLTypes']
                          for scheme in entry['CFBundleURLSchemes']], ['wesh'])
        for key in ['NSBluetoothAlwaysUsageDescription', 'NSBluetoothPeripheralUsageDescription', 'NSCameraUsageDescription']:
            self.assertTrue(self.info[key])
        self.assertEqual(set(self.info['UIBackgroundModes']), {'bluetooth-central', 'bluetooth-peripheral'})

    def test_mac_bluetooth_camera_network_and_shared_container_rights_are_preserved(self):
        for key in ['com.apple.security.app-sandbox', 'com.apple.security.device.bluetooth',
                    'com.apple.security.device.camera', 'com.apple.security.network.client',
                    'com.apple.security.network.server']:
            self.assertIs(self.entitlements[key], True)
        self.assertEqual(self.entitlements['com.apple.security.application-groups'], ['$(APP_GROUP_ID)'])

    def test_existing_transport_crypto_and_font_inputs_are_preserved(self):
        # Presence of these reviewed inputs is a positive keep contract, not a
        # claim about native reproducibility or final legal-notice completeness.
        for path in ['localPackages/Arti/Package.swift', 'localPackages/Arti/Cargo.lock',
                     'localPackages/Arti/Frameworks/include/arti.h',
                     'bitchat/Views/Wesh/Pave/Fonts/Archivo-OFL.txt', 'LICENSE']:
            self.assertTrue((ROOT / path).is_file(), path)
        for resources in self.resources.values():
            self.assertIn('bitchat/Views/Wesh/Pave/Fonts/Archivo-OFL.txt', resources)
            self.assertIn('bitchat/Views/Wesh/Pave/Fonts/ArchivoExtraCondensedBlack.ttf', resources)
        framework = load_plist('localPackages/Arti/Frameworks/arti.xcframework/Info.plist')
        self.assertEqual({entry['SupportedPlatform'] for entry in framework['AvailableLibraries']}, {'ios', 'macos'})

    def test_openstep_parser_handles_comments_quoted_paths_and_exceptions(self):
        value = parse_openstep('''// synthetic only
        { objects = { A /* comment */ = { path = "folder/read me.md";
          membershipExceptions = ("Info.plist", "folder/read me.md",); }; }; }''')
        self.assertEqual(value['objects']['A'], {'path': 'folder/read me.md',
                         'membershipExceptions': ['Info.plist', 'folder/read me.md']})

    def test_openstep_parser_rejects_ambiguous_or_truncated_input(self):
        for source in ['{ a = one; a = two; }', '{ a = (one two); }', '{ a = one;', '{} garbage']:
            with self.subTest(source=source), self.assertRaises(ValueError):
                parse_openstep(source)


if __name__ == '__main__':
    unittest.main()
