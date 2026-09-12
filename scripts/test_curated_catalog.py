"""Offline operator regressions. All HTTP is synthetic; no local/remote DB use."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('curated_operator', Path(__file__).with_name('curated-catalog.py'))
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)

SUBJECT = '00000000-0000-4000-8000-000000000003'
ITEM = '10000000-0000-4000-8000-000000000001'

class BoundaryTests(unittest.TestCase):
    def test_explicit_production_project_resolves_only_pinned_origin(self):
        self.assertEqual(cli.project_origin(cli.PRODUCTION_PROJECT), cli.PRODUCTION_ORIGIN)
        with self.assertRaises(cli.OperatorError): cli.project_origin('staging-or-other-project')

    def test_upload_destination_rejects_cross_project_and_non_tus_paths(self):
        for value in ('https://evil.example/storage/v1/upload/resumable/item',
                      cli.PRODUCTION_ORIGIN + '/rest/v1/private',
                      cli.PRODUCTION_ORIGIN + '/storage/v1/upload/resumable/item?token=secret',
                      cli.PRODUCTION_ORIGIN + '/storage/v1/upload/resumable/item#fragment',
                      'https://user:password@' + cli.PRODUCTION_PROJECT + '.supabase.co/storage/v1/upload/resumable/item',
                      cli.PRODUCTION_ORIGIN + '/storage/v1/upload/resumable/'):
            with self.subTest(url=value), self.assertRaises(cli.OperatorError): cli.validate_upload_url(value)

    def test_operation_identity_is_stable_for_retry_and_changes_for_payload_or_actor(self):
        payload = {'upload_session_id': ITEM, 'expected_revision': 1}
        first = cli.operation_identity(SUBJECT, ITEM, 'a' * 64, 'submit', payload)
        self.assertIsInstance(first, tuple)
        self.assertEqual(first, cli.operation_identity(SUBJECT, ITEM, 'a' * 64, 'submit', dict(reversed(list(payload.items())))))
        self.assertNotEqual(first, cli.operation_identity(SUBJECT, ITEM, 'a' * 64, 'submit', {**payload, 'expected_revision': 2}))
        self.assertNotEqual(first, cli.operation_identity(ITEM, ITEM, 'a' * 64, 'submit', payload))

    def test_manifest_rejects_cross_project_before_accessing_media(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'manifest.json'
            path.write_text(json.dumps({'schema': 'wali.curated_catalog.batch.v1', 'project_ref': 'wrong', 'items': []}))
            with self.assertRaises(cli.OperatorError): cli.load_manifest(path, Path(directory), ITEM)


import base64
import contextlib
import hashlib
import io
import os
from unittest.mock import patch

SESSION = '70000000-0000-4000-8000-000000000001'
SUBMISSION = '71000000-0000-4000-8000-000000000001'
CATEGORY = '20000000-0000-4000-8000-000000000001'
NOW = 2_000_000_000
TUS = cli.PRODUCTION_ORIGIN + '/storage/v1/upload/resumable/fixture'

def fixture_token(subject=SUBJECT, aal='aal2'):
    claims = {'sub': subject, 'iss': cli.PRODUCTION_ORIGIN + '/auth/v1', 'aud': 'authenticated',
              'role': 'authenticated', 'aal': aal, 'iat': NOW - 10, 'exp': NOW + 3600}
    part = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
    return 'fixture.' + part + '.notASignedToken'


class FakeServer:
    """Only synthetic Auth/Edge/TUS responses; never opens a network connection."""
    def __init__(self, size):
        self.size, self.uploaded = size, bytearray()
        self.calls, self.commands = [], []
        self.created_keys, self.new_sessions = set(), 0
        self.auth_status = 200
        self.fail_patch_once = self.fail_complete_once = self.fail_save_once = False
        self.saved_results = {}
        self.complete_result = None
        self.state, self.revision = 'processing', 2
        self.patch_hook = None
        self.create_overrides, self.head_overrides = {}, {}
        self.error_code, self.error_status = None, 403

    def send(self, method, url, headers, body, maximum_bytes):
        self.calls.append((method, url, dict(headers), body))
        if url.endswith('/auth/v1/user'):
            return cli.HTTPResponse(self.auth_status, {}, json.dumps({'id': SUBJECT}).encode())
        if url.endswith('/functions/v1/curated-catalog-command'):
            request = json.loads(body); self.commands.append(request)
            action, payload = request['action'], request['payload']
            if self.error_code:
                return cli.HTTPResponse(self.error_status, {}, json.dumps({'error': {'code': self.error_code, 'message': 'private diagnostic must not escape'}}).encode())
            if action == 'accept_attestation':
                result = {'document_kind': 'catalog_license_attestation', 'accepted_attestation_version': cli.ATTESTATION_VERSION, 'current_attestation_version': cli.ATTESTATION_VERSION}
            elif action == 'create_upload':
                if request['idempotency_key'] not in self.created_keys:
                    self.created_keys.add(request['idempotency_key']); self.new_sessions += 1
                result = {'upload_session_id': SESSION, 'revision': 9 if self.complete_result else 2,
                    'expires_at': '2040-01-01T00:00:00Z', 'upload_endpoint': TUS,
                    'required_headers': {'Tus-Resumable': '1.0.0'},
                    'scoped_upload_token': headers['Authorization'].removeprefix('Bearer '), **self.create_overrides}
            elif action == 'complete_upload':
                if self.complete_result is None:
                    assert payload['expected_session_revision'] == 2
                    self.complete_result = {'submission_id': SUBMISSION, 'revision': 2, 'generation': 1,
                        'state': 'processing', 'processing_status_key': SUBMISSION + ':1'}
                result = dict(self.complete_result)
                if self.fail_complete_once:
                    self.fail_complete_once = False
                    raise cli.OperatorError('transport_unavailable', ambiguous=True)
            elif action == 'status':
                submission = None
                if self.complete_result:
                    identity = {'submission_id': SUBMISSION, 'revision': self.revision, 'generation': 1, 'state': self.state}
                    progress = {**identity, 'progress': 0.5, 'safe_error_code': None, 'media_facts': None,
                        'generated_variants': [], 'duplicate_warning': False, 'suggestions': [], 'findings': []}
                    submission = {**identity, 'processing': progress}
                result = {'upload_session_id': SESSION, 'revision': 3 if submission else 2,
                    'upload_state': 'completed' if submission else 'uploading', 'expires_at': '2040-01-01T00:00:00Z', 'submission': submission}
            elif action == 'save_draft':
                key = request['idempotency_key']
                if key not in self.saved_results:
                    self.revision += 1; self.state = 'ready_for_submission'
                    self.saved_results[key] = {'submission_id': SUBMISSION, 'revision': self.revision,
                        'generation': 1, 'state': self.state, 'field_errors': []}
                result = self.saved_results[key]
                if self.fail_save_once:
                    self.fail_save_once = False
                    raise cli.OperatorError('transport_unavailable', ambiguous=True)
            elif action in ('submit', 'withdraw'):
                self.revision += 1; self.state = 'submitted' if action == 'submit' else 'withdrawn'
                result = {'submission_id': SUBMISSION, 'revision': self.revision, 'generation': 1, 'state': self.state}
                if action == 'withdraw': result['field_errors'] = []
            else:
                raise AssertionError('unexpected public action')
            return cli.HTTPResponse(201 if action in ('create_upload', 'accept_attestation') else 200, {},
                json.dumps({'api_version': 'curated_catalog.v1', 'request_id': request['request_id'], 'data': result}).encode())
        assert url == TUS
        assert headers['Tus-Resumable'] == '1.0.0'
        if method == 'HEAD':
            return cli.HTTPResponse(200, {'Tus-Resumable': '1.0.0', 'Upload-Length': str(self.size), 'Upload-Offset': str(len(self.uploaded)), **self.head_overrides})
        assert method == 'PATCH'
        assert headers['Content-Type'] == 'application/offset+octet-stream'
        assert int(headers['Upload-Offset']) == len(self.uploaded)
        self.uploaded.extend(body)
        if self.patch_hook: self.patch_hook()
        if self.fail_patch_once:
            self.fail_patch_once = False
            raise cli.OperatorError('transport_unavailable', ambiguous=True)
        return cli.HTTPResponse(204, {'Tus-Resumable': '1.0.0', 'Upload-Offset': str(len(self.uploaded))})


class OperatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wali-curated-unit-', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.media = self.root / 'media'; self.media.mkdir(mode=0o700)
        self.file = self.media / 'fixture.mp4'; self.bytes = b'fixture-video-bytes'
        self.file.write_bytes(self.bytes)
        self.item = {'item_id': ITEM, 'file_path': str(self.file), 'sha256': hashlib.sha256(self.bytes).hexdigest(),
            'byte_count': len(self.bytes), 'container_hint': 'video/mp4', 'original_filename': 'fixture.mp4', 'target': {'kind': 'new'},
            'draft': {'title': 'Synthetic fixture', 'description': 'Offline unit fixture only.', 'primary_category_id': CATEGORY,
                'suggested_tag_ids': [], 'content_warning': None, 'rights_basis': 'licensed', 'rights_holder': 'Fixture publisher',
                'license_id': CATEGORY, 'source_url': 'https://publisher.example.invalid/fixture', 'attribution_text': 'Synthetic credit.',
                'proof_object_ids': [], 'attests_rights': True, 'attestation_version': cli.ATTESTATION_VERSION}}
        self.manifest = self.root / 'manifest.json'
        self.write_manifest()
        self.fingerprint = cli.item_fingerprint(self.item)
        self.server = FakeServer(len(self.bytes))
        self.client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), self.server, now=lambda: NOW)
        self.client.authenticate()
        self.chunk = patch.object(cli, 'CHUNK_BYTES', 4); self.chunk.start()

    def tearDown(self):
        self.chunk.stop(); self.temp.cleanup()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({'schema': 'wali.curated_catalog.batch.v1', 'project_ref': cli.PRODUCTION_PROJECT, 'items': [self.item]}))

    def store(self, subject=SUBJECT, fingerprint=None):
        return cli.ReceiptStore(self.root / 'receipts', subject, ITEM, fingerprint or self.fingerprint)

    def upload(self):
        with self.store() as store:
            return cli.Operator(self.client, store, self.item, self.media).upload()

    def test_upload_preserves_source_and_keeps_bearer_out_of_receipts(self):
        result = self.upload()
        self.assertEqual(result['state'], 'processing')
        self.assertEqual(bytes(self.server.uploaded), self.bytes)
        self.assertEqual(self.file.read_bytes(), self.bytes)
        self.assertEqual(self.server.new_sessions, 1)
        self.assertEqual([r['action'] for r in self.server.commands], ['create_upload', 'complete_upload'])
        receipt = (self.root / 'receipts' / (ITEM + '.json')).read_bytes()
        self.assertNotIn(fixture_token().encode(), receipt)
        self.assertNotIn(b'scoped_upload_token', receipt)
        self.assertNotIn(b'Authorization', receipt)
        self.assertEqual((self.root / 'receipts').stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / 'receipts' / (ITEM + '.json')).stat().st_mode & 0o777, 0o600)

    def test_lost_patch_response_resumes_from_confirmed_server_offset(self):
        self.server.fail_patch_once = True
        with self.assertRaises(cli.OperatorError): self.upload()
        self.assertEqual(bytes(self.server.uploaded), self.bytes[:4])
        self.upload()
        self.assertEqual(bytes(self.server.uploaded), self.bytes)
        creates = [r for r in self.server.commands if r['action'] == 'create_upload']
        self.assertEqual(creates[0], creates[1]); self.assertEqual(self.server.new_sessions, 1)
        patches = [call for call in self.server.calls if call[0] == 'PATCH']
        self.assertEqual([int(call[2]['Upload-Offset']) for call in patches], list(range(0, len(self.bytes), 4)))

    def test_lost_completion_replays_exact_old_revision_without_create_or_tus(self):
        self.server.fail_complete_once = True
        with self.assertRaises(cli.OperatorError): self.upload()
        before = len(self.server.calls)
        self.upload()
        after = self.server.calls[before:]
        self.assertEqual(len(after), 1)
        completions = [r for r in self.server.commands if r['action'] == 'complete_upload']
        self.assertEqual(completions[0], completions[1])
        self.assertEqual(completions[1]['payload']['expected_session_revision'], 2)
        self.assertEqual(self.server.new_sessions, 1)

    def test_completed_upload_checks_status_without_another_create_or_patch(self):
        self.upload(); before = len(self.server.calls)
        result = self.upload()
        self.assertEqual(result['submission']['state'], 'processing')
        self.assertEqual([json.loads(c[3])['action'] for c in self.server.calls[before:]], ['status'])

    def test_unexplained_offset_does_not_adopt_someone_elses_bytes(self):
        self.server.uploaded.extend(b'x')
        with self.assertRaisesRegex(cli.OperatorError, 'unexplained_upload_offset'): self.upload()
        self.assertFalse(any(c[0] == 'PATCH' for c in self.server.calls))
        self.assertFalse(any(c['action'] == 'complete_upload' for c in self.server.commands))

    def test_mismatched_tus_length_or_headers_are_rejected(self):
        for headers in ({'Upload-Length': '999'}, {'Upload-Offset': '-1'}, {'Upload-Offset': '01'}, {'Tus-Resumable': '2.0.0'}, {'Upload-Offset': '999'}):
            self.server.head_overrides = headers
            with self.subTest(headers=headers), self.assertRaises(cli.OperatorError): self.client.tus_head(TUS, len(self.bytes))

    def test_changed_source_is_rejected_before_create(self):
        self.file.write_bytes(b'x' * len(self.bytes))
        with self.assertRaisesRegex(cli.OperatorError, 'file_digest_changed'): self.upload()
        self.assertEqual(self.server.commands, [])

    def test_file_change_between_patches_prevents_completion(self):
        self.server.patch_hook = lambda: self.file.write_bytes(b'x' * len(self.bytes))
        with self.assertRaisesRegex(cli.OperatorError, 'file_changed'): self.upload()
        self.assertFalse(any(c['action'] == 'complete_upload' for c in self.server.commands))
        self.assertEqual(len([c for c in self.server.calls if c[0] == 'PATCH']), 1)

    def test_expired_resource_is_not_uploaded(self):
        self.server.create_overrides = {'expires_at': '2020-01-01T00:00:00Z'}
        with self.assertRaisesRegex(cli.OperatorError, 'upload_expired'): self.upload()
        self.assertFalse(any(c[0] in ('HEAD', 'PATCH') for c in self.server.calls))

    def test_changed_metadata_or_account_cannot_reuse_receipt(self):
        with self.store(): pass
        with self.assertRaisesRegex(cli.OperatorError, 'receipt_identity_changed'): self.store(fingerprint='f' * 64)
        with self.assertRaisesRegex(cli.OperatorError, 'receipt_identity_changed'): self.store(subject=ITEM)

    def test_symlink_source_or_outside_root_is_refused(self):
        other = self.root / 'outside.mp4'; other.write_bytes(self.bytes)
        self.file.unlink(); self.file.symlink_to(other)
        with self.assertRaisesRegex(cli.OperatorError, 'symlink_path_refused'): self.upload()
        self.item['file_path'] = str(other); self.write_manifest()
        with self.assertRaisesRegex(cli.OperatorError, 'media_outside_root'): cli.load_manifest(self.manifest, self.media, ITEM)

    def test_fake_jwt_claims_are_insufficient_when_auth_denies_token(self):
        self.server.auth_status = 401
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), self.server, now=lambda: NOW)
        with self.assertRaisesRegex(cli.OperatorError, 'authentication_required'): client.authenticate()
        self.assertIsNone(client.subject); self.assertEqual(self.server.commands, [])

    def test_auth_acceptance_still_requires_aal2_and_exact_subject(self):
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(aal='aal1'), self.server, now=lambda: NOW)
        with self.assertRaisesRegex(cli.OperatorError, 'mfa_required'): client.authenticate()
        other = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(subject=ITEM), self.server, now=lambda: NOW)
        with self.assertRaises(cli.OperatorError): other.authenticate()

    def test_upload_does_not_auto_submit_and_not_ready_submit_respects_backpressure(self):
        self.upload()
        with self.store() as store:
            with self.assertRaisesRegex(cli.OperatorError, 'submission_not_ready'):
                cli.Operator(self.client, store, self.item, self.media).transition('submit')
        self.assertFalse(any(c['action'] == 'submit' for c in self.server.commands))
        self.server.state = 'ready_for_submission'; self.server.revision = 3
        with self.store() as store:
            result = cli.Operator(self.client, store, self.item, self.media).transition('submit')
        self.assertEqual(result['state'], 'submitted')
        submit = self.server.commands[-1]
        self.assertEqual(submit['payload'], {'submission_id': SUBMISSION, 'expected_revision': 3, 'expected_generation': 1, 'attestation_version': cli.ATTESTATION_VERSION})
        self.assertNotIn('actor_id', submit); self.assertNotIn('actor_aal', submit)
        self.assertTrue(all(c['action'] not in ('approve', 'publish', 'bind_upload') for c in self.server.commands))

    def test_quota_denial_does_not_change_retry_identity_or_create_extra_session(self):
        self.server.error_code = 'rate_limited'; self.server.error_status = 429
        with self.assertRaisesRegex(cli.OperatorError, 'rate_limited'): self.upload()
        denied = self.server.commands[0]
        self.server.error_code = None
        self.upload()
        self.assertEqual(denied, self.server.commands[1]); self.assertEqual(self.server.new_sessions, 1)

    def test_server_upload_token_or_headers_cannot_redirect_credentials(self):
        for override in ({'scoped_upload_token': 'another-secret'}, {'required_headers': {'Authorization': 'Bearer another-secret'}}, {'upload_endpoint': 'https://evil.example/storage/v1/upload/resumable/x'}):
            self.server.create_overrides = override
            with self.subTest(override=override), self.assertRaisesRegex(cli.OperatorError, 'invalid_service_response'): self.upload()
            self.assertFalse(any(c[0] == 'PATCH' for c in self.server.calls))
            receipt = (self.root / 'receipts' / (ITEM + '.json')).read_text()
            self.assertNotIn('another-secret', receipt)

    def test_validate_action_is_offline_and_outputs_no_credentials(self):
        out = io.StringIO()
        with patch.object(cli, 'Client', side_effect=AssertionError('must not initialize network client')), contextlib.redirect_stdout(out):
            result = cli.main(['validate', '--project-ref', cli.PRODUCTION_PROJECT, '--manifest', str(self.manifest), '--media-root', str(self.media), '--item', ITEM])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(out.getvalue())['status'], 'validated_offline')

    def test_token_input_requires_pipe_and_never_a_regular_file(self):
        token_file = self.root / 'synthetic-token'; token_file.write_text(fixture_token())
        with token_file.open('rb') as stream:
            with self.assertRaisesRegex(cli.OperatorError, 'token_requires_private_pipe'): cli.read_token(stream.fileno())
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, fixture_token().encode() + b'\n'); os.close(write_fd); write_fd = None
            self.assertEqual(cli.read_token(read_fd), fixture_token())
        finally:
            os.close(read_fd)
            if write_fd is not None: os.close(write_fd)

    def test_redirect_handler_stops_before_second_request(self):
        with self.assertRaisesRegex(cli.OperatorError, 'redirect_refused'):
            cli.NoRedirect().redirect_request(None, None, 307, 'redirect', {}, 'https://evil.example')
        class Redirect:
            calls = 0
            def send(self, *_):
                self.calls += 1
                return cli.HTTPResponse(307, {'location': 'https://evil.example?secret=do-not-log'})
        transport = Redirect()
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), transport, now=lambda: NOW)
        with self.assertRaisesRegex(cli.OperatorError, 'redirect_refused'): client.authenticate()
        self.assertEqual(transport.calls, 1)

    def test_attestation_text_matches_the_immutable_edge_version(self):
        source = (Path(__file__).resolve().parents[1] / 'supabase/functions/_shared/curated-license-attestation.ts').read_text()
        self.assertIn(json.dumps(cli.ATTESTATION_TEXT), source)
        self.assertIn('version: "' + cli.ATTESTATION_VERSION + '"', source)


    def test_draft_correction_preserves_media_identity_and_uses_current_revision(self):
        self.upload()
        old_fingerprint = cli.item_fingerprint(self.item)
        self.item['draft']['attribution_text'] = 'Corrected publisher credit.'
        self.assertEqual(cli.item_fingerprint(self.item), old_fingerprint)
        self.server.state, self.server.revision = 'changes_requested', 7
        with self.store() as store:
            result = cli.Operator(self.client, store, self.item, self.media).save_draft()
        self.assertEqual(result['revision'], 8)
        self.assertEqual(self.server.commands[-1]['payload']['expected_revision'], 7)
        self.assertEqual(self.server.commands[-1]['payload']['draft']['attribution_text'], 'Corrected publisher credit.')
        self.assertEqual(self.server.new_sessions, 1)

    def test_lost_save_replays_its_original_draft_before_later_credit_correction(self):
        self.upload(); self.server.state, self.server.revision = 'changes_requested', 7
        self.item['draft']['attribution_text'] = 'First corrected credit.'
        self.server.fail_save_once = True
        with self.store() as store:
            with self.assertRaises(cli.OperatorError): cli.Operator(self.client, store, self.item, self.media).save_draft()
        self.item['draft']['attribution_text'] = 'Second corrected credit.'
        with self.store() as store: cli.Operator(self.client, store, self.item, self.media).save_draft()
        saves = [c for c in self.server.commands if c['action'] == 'save_draft']
        self.assertEqual(saves[0], saves[1])
        self.assertEqual(saves[1]['payload']['draft']['attribution_text'], 'First corrected credit.')
        with self.store() as store: cli.Operator(self.client, store, self.item, self.media).save_draft()
        self.assertEqual(self.server.commands[-1]['payload']['draft']['attribution_text'], 'Second corrected credit.')
        self.assertEqual(self.server.commands[-1]['payload']['expected_revision'], 8)
        self.assertEqual(self.server.new_sessions, 1)

    def test_pending_completion_draft_stays_frozen_across_manifest_correction(self):
        original = dict(self.item['draft'])
        self.server.fail_complete_once = True
        with self.assertRaises(cli.OperatorError): self.upload()
        self.item['draft']['attribution_text'] = 'A later credit correction.'
        self.upload()
        completions = [c for c in self.server.commands if c['action'] == 'complete_upload']
        self.assertEqual(completions[0], completions[1])
        self.assertEqual(completions[1]['payload']['draft'], original)


class AdditionalSafetyTests(unittest.TestCase):
    def test_fixed_origin_transport_does_not_discover_environment_proxies(self):
        with patch.object(cli.urllib.request, 'getproxies', side_effect=AssertionError('proxy discovery refused')):
            cli.HTTPTransport()

    def test_pending_patch_rejects_incorrect_response_offset(self):
        class WrongOffset:
            def send(self, *_):
                return cli.HTTPResponse(204, {'Tus-Resumable': '1.0.0', 'Upload-Offset': '99'})
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), WrongOffset(), now=lambda: NOW)
        client.subject, client.expires_at = SUBJECT, NOW + 3600
        with self.assertRaisesRegex(cli.OperatorError, 'invalid_upload_offset'): client.tus_patch(TUS, 0, b'abcd')

    def test_private_unknown_server_error_is_not_echoed(self):
        class PrivateError:
            def send(self, *_): return cli.HTTPResponse(503, {}, b'{"error":"private-secret-detail"}')
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), PrivateError(), now=lambda: NOW)
        client.subject, client.expires_at = SUBJECT, NOW + 3600
        with self.assertRaises(cli.OperatorError) as caught:
            client.command('status', {'upload_session_id': SESSION}, ITEM, 'idempotency_fixture')
        self.assertEqual(caught.exception.code, 'service_error')
        self.assertTrue(caught.exception.ambiguous)
        self.assertNotIn('private-secret', str(caught.exception))

    def test_client_rejects_hidden_or_publication_commands_before_transport(self):
        class NoHTTP:
            def send(self, *_): raise AssertionError('must not send')
        client = cli.Client(cli.PRODUCTION_PROJECT, 'sb_publishable_fixture', fixture_token(), NoHTTP(), now=lambda: NOW)
        client.subject, client.expires_at = SUBJECT, NOW + 3600
        for action in ('bind_upload', 'approve', 'publish', 'sql'):
            with self.subTest(action=action), self.assertRaisesRegex(cli.OperatorError, 'unsupported_action'):
                client.command(action, {}, ITEM, 'idempotency_fixture')

    def test_text_limits_match_edge_utf16_units(self):
        self.assertEqual(cli.text('🌄' * 60, 120), '🌄' * 60)
        with self.assertRaises(cli.OperatorError): cli.text('🌄' * 61, 120)



if __name__ == '__main__': unittest.main()
