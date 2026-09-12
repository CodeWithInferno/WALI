#!/usr/bin/env python3
"""One-item staff catalog operator. No SQL, privileged tokens, review or publication."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import stat
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid

PRODUCTION_PROJECT = 'afgxvhhubqzgpijcstsv'
PRODUCTION_ORIGIN = 'https://' + PRODUCTION_PROJECT + '.supabase.co'
ATTESTATION_VERSION = '2026-09-12'
ATTESTATION_TEXT = ('I attest that I am authorized under the recorded agreement to process, host, distribute, '
    'and display each selected work for WALI. I will stay within the recorded license scope, preserve original '
    'authorship and all required source, artist, and publisher credits, and retain the agreement reference. '
    'This declaration records my publishing authority; it does not grant new rights or accept public Creator Terms.')
MAX_FILE_BYTES = 1_073_741_824
CHUNK_BYTES = 6 * 1024 * 1024
ACTIONS = {'accept_attestation', 'create_upload', 'complete_upload', 'save_draft', 'status', 'submit', 'withdraw'}
STATES = {'draft', 'uploading', 'uploaded', 'processing', 'processing_failed', 'ready_for_submission',
          'submitted', 'under_review', 'changes_requested', 'approved', 'rejected', 'published', 'withdrawn'}
ERROR_CODES = {'invalid_request', 'unsupported_api_version', 'authentication_required', 'forbidden',
    'mfa_required', 'account_suspended', 'catalog_admission_unavailable', 'catalog_attestation_required',
    'rate_limited', 'stale_revision', 'idempotency_conflict', 'rights_incomplete', 'upload_expired',
    'upload_incomplete', 'upload_changed', 'submission_not_ready', 'processing_capacity_unavailable',
    'temporarily_unavailable'}


class OperatorError(Exception):
    def __init__(self, code, *, ambiguous=False):
        self.code = code
        self.ambiguous = ambiguous
        super().__init__(code)


def require(condition, code='invalid_input'):
    if not condition:
        raise OperatorError(code)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(',', ':')).encode('utf-8')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def parse_json(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(OperatorError('invalid_json')))
    except (ValueError, UnicodeError):
        raise OperatorError('invalid_json') from None


def exact(value, keys, code='invalid_input'):
    require(isinstance(value, dict) and set(value) == set(keys), code)
    return value


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', value) is not None)
    return value


def integer(value, minimum=0, maximum=9_007_199_254_740_991):
    require(type(value) is int and minimum <= value <= maximum)
    return value


def text(value, maximum, nonblank=True):
    require(isinstance(value, str))
    try: units = len(value.encode('utf-16-le')) // 2
    except UnicodeError: raise OperatorError('invalid_input') from None
    require(1 <= units <= maximum
            and value == unicodedata.normalize('NFC', value)
            and not any(ord(c) <= 31 or 127 <= ord(c) <= 159 for c in value)
            and (not nonblank or bool(value.strip())))
    return value


def project_origin(value):
    require(value == PRODUCTION_PROJECT, 'wrong_project')
    return PRODUCTION_ORIGIN


def https_url(value):
    text(value, 2048)
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme == 'https' and bool(parsed.netloc) and not parsed.username
            and not parsed.password and not parsed.fragment, 'invalid_url')
    return value


def validate_upload_url(value, origin=PRODUCTION_ORIGIN):
    require(origin == PRODUCTION_ORIGIN, 'wrong_project')
    text(value, 2048)
    parsed = urllib.parse.urlsplit(value)
    base = urllib.parse.urlsplit(origin)
    prefix = '/storage/v1/upload/resumable/'
    require(parsed.scheme == base.scheme and parsed.netloc == base.netloc
            and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment
            and parsed.path.startswith(prefix) and len(parsed.path) > len(prefix)
            and all(part not in ('.', '..') for part in urllib.parse.unquote(parsed.path).split('/')),
            'unsafe_upload_destination')
    return value


def item_fingerprint(item):
    # Metadata/rights can be corrected explicitly; media, destination and initial
    # upload identity cannot change underneath an existing receipt.
    return digest(canonical({key: item[key] for key in ('item_id', 'file_path', 'sha256',
        'byte_count', 'container_hint', 'original_filename', 'target')}))


def operation_identity(subject, item_id, fingerprint, action, payload):
    identity = digest(canonical({'project_ref': PRODUCTION_PROJECT, 'subject': identifier(subject),
        'item_id': identifier(item_id), 'item_fingerprint': fingerprint, 'action': action, 'payload': payload}))
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'wali.curated_catalog.v1:' + identity)), 'cc_' + identity[:60]


def checked_path(value, *, directory=False, may_not_exist=False):
    path = Path(value)
    require(path.is_absolute() and os.path.normpath(str(path)) == str(path), 'unsafe_local_path')
    for entry in [*reversed(path.parents), path]:
        try:
            info = entry.lstat()
        except FileNotFoundError:
            require(may_not_exist and entry == path, 'local_path_missing')
            return path
        require(not stat.S_ISLNK(info.st_mode), 'symlink_path_refused')
        if entry != path:
            require(stat.S_ISDIR(info.st_mode), 'unsafe_local_path')
        else:
            require(stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode), 'unsafe_local_path')
    return path


def read_local_json(path, maximum):
    path = checked_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        raw = stream.read(maximum + 1)
    require(len(raw) <= maximum, 'local_document_too_large')
    return parse_json(raw)


def validate_draft(value):
    exact(value, ['title', 'description', 'primary_category_id', 'suggested_tag_ids', 'content_warning',
        'rights_basis', 'rights_holder', 'license_id', 'source_url', 'attribution_text', 'proof_object_ids',
        'attests_rights', 'attestation_version'])
    text(value['title'], 120); text(value['description'], 2000)
    identifier(value['primary_category_id']); identifier(value['license_id'])
    tags = value['suggested_tag_ids']
    require(isinstance(tags, list) and len(tags) <= 20)
    for tag in tags: identifier(tag)
    require(len(set(tags)) == len(tags))
    if value['content_warning'] is not None: text(value['content_warning'], 500)
    require(value['rights_basis'] == 'licensed' and value['proof_object_ids'] == []
            and value['attests_rights'] is True and value['attestation_version'] == ATTESTATION_VERSION)
    text(value['rights_holder'], 160); text(value['attribution_text'], 500); https_url(value['source_url'])
    return value


def load_manifest(path, media_root, item_id):
    root = checked_path(media_root, directory=True)
    manifest = read_local_json(path, 262_144)
    exact(manifest, ['schema', 'project_ref', 'items'])
    require(manifest['schema'] == 'wali.curated_catalog.batch.v1')
    project_origin(manifest['project_ref'])
    items = manifest['items']
    require(isinstance(items, list) and 1 <= len(items) <= 24, 'invalid_batch_size')
    ids, paths, selected = set(), set(), None
    for item in items:
        exact(item, ['item_id', 'file_path', 'sha256', 'byte_count', 'container_hint', 'original_filename', 'target', 'draft'])
        current_id = identifier(item['item_id'])
        require(current_id not in ids, 'duplicate_item'); ids.add(current_id)
        filename = text(item['original_filename'], 255)
        require(filename not in ('.', '..') and '/' not in filename and '\\' not in filename)
        require(item['container_hint'] in ('video/mp4', 'video/quicktime'))
        integer(item['byte_count'], 1, MAX_FILE_BYTES)
        require(isinstance(item['sha256'], str) and re.fullmatch('[0-9a-f]{64}', item['sha256']) is not None)
        raw_path = item['file_path']
        require(isinstance(raw_path, str), 'unsafe_local_path')
        media = Path(raw_path)
        require(media.is_absolute() and os.path.normpath(raw_path) == raw_path
                and media.is_relative_to(root) and media != root, 'media_outside_root')
        require(raw_path not in paths, 'duplicate_file'); paths.add(raw_path)
        target = item['target']
        require(isinstance(target, dict))
        if target.get('kind') == 'new': exact(target, ['kind'])
        else:
            exact(target, ['kind', 'wallpaper_id', 'expected_revision'])
            require(target['kind'] == 'wallpaper_update'); identifier(target['wallpaper_id']); integer(target['expected_revision'])
        validate_draft(item['draft'])
        if current_id == item_id: selected = item
    require(selected is not None, 'item_not_found')
    return selected


class FileSource:
    """An open immutable snapshot with hashes for each bounded upload range."""
    def __init__(self, item, media_root):
        path = checked_path(item['file_path'])
        root = checked_path(media_root, directory=True)
        require(path.is_relative_to(root), 'media_outside_root')
        self.fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            self.before = self._state()
            self.size = item['byte_count']
            require(self.before[2] == self.size, 'file_size_changed')
            self.sha256 = item['sha256']
            self.chunk_hashes = []
            total = hashlib.sha256()
            for offset in range(0, self.size, CHUNK_BYTES):
                chunk = os.pread(self.fd, min(CHUNK_BYTES, self.size - offset), offset)
                require(len(chunk) == min(CHUNK_BYTES, self.size - offset), 'file_changed')
                total.update(chunk); self.chunk_hashes.append(digest(chunk))
            require(total.hexdigest() == self.sha256, 'file_digest_changed')
            self.check()
        except BaseException:
            os.close(self.fd)
            raise

    def _state(self):
        info = os.fstat(self.fd)
        require(stat.S_ISREG(info.st_mode), 'unsafe_local_path')
        return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns

    def check(self):
        require(self._state() == self.before, 'file_changed')

    def read(self, offset):
        self.check()
        integer(offset, 0, self.size - 1)
        index = offset // CHUNK_BYTES
        start = index * CHUNK_BYTES
        chunk = os.pread(self.fd, min(CHUNK_BYTES, self.size - start), start)
        require(digest(chunk) == self.chunk_hashes[index], 'file_changed')
        self.check()
        return chunk[offset - start:]

    def close(self): os.close(self.fd)
    def __enter__(self): return self
    def __exit__(self, *_): self.close()


class HTTPResponse:
    def __init__(self, status, headers, body=b''):
        self.status = status
        self.headers = {name.lower(): value for name, value in headers.items()}
        self.body = body


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        raise OperatorError('redirect_refused', ambiguous=True)


class HTTPTransport:
    def __init__(self): self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def send(self, method, url, headers, body, maximum_bytes):
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            response = self.opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        except (urllib.error.URLError, TimeoutError, OSError):
            raise OperatorError('transport_unavailable', ambiguous=True) from None
        with response:
            raw = response.read(maximum_bytes + 1)
            if len(raw) > maximum_bytes: raise OperatorError('response_too_large', ambiguous=True)
            if 300 <= response.status < 400:
                raise OperatorError('redirect_refused', ambiguous=True)
            return HTTPResponse(response.status, dict(response.headers.items()), raw)


class Client:
    def __init__(self, project, publishable_key, token, transport=None, now=time.time):
        self.origin = project_origin(project)
        require(isinstance(publishable_key, str) and 1 <= len(publishable_key) <= 8192)
        require(isinstance(token, str) and 1 <= len(token) <= 8192
                and re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token) is not None,
                'invalid_access_token')
        self.publishable_key, self.token = publishable_key, token
        self.transport, self.now = transport or HTTPTransport(), now
        self.subject, self.expires_at = None, 0

    def _send(self, method, url, body=None, extra_headers=None, maximum=65_536):
        allowed = {self.origin + '/auth/v1/user', self.origin + '/functions/v1/curated-catalog-command'}
        if url not in allowed: validate_upload_url(url, self.origin)
        if url != self.origin + '/auth/v1/user':
            require(self.subject is not None and self.expires_at > self.now(), 'authentication_required')
        headers = {'Authorization': 'Bearer ' + self.token, 'apikey': self.publishable_key}
        headers.update(extra_headers or {})
        response = self.transport.send(method, url, headers, body, maximum)
        if 300 <= response.status < 400: raise OperatorError('redirect_refused', ambiguous=True)
        if len(response.body) > maximum: raise OperatorError('response_too_large', ambiguous=True)
        return response

    def authenticate(self):
        response = self._send('GET', self.origin + '/auth/v1/user')
        require(response.status == 200, 'authentication_required')
        user = parse_json(response.body)
        require(isinstance(user, dict) and isinstance(user.get('id'), str), 'authentication_required')
        # Auth must accept this same token before any decoded claim is trusted.
        try:
            part = self.token.split('.')[1]
            claims = parse_json(base64.urlsafe_b64decode(part + '=' * ((4-len(part) % 4) % 4)))
            require(isinstance(claims, dict) and identifier(claims.get('sub')) == user['id'], 'authentication_required')
            require(claims.get('iss') == self.origin + '/auth/v1' and claims.get('aud') in ('authenticated', ['authenticated'])
                    and claims.get('role') == 'authenticated', 'authentication_required')
            require(type(claims.get('exp')) is int and claims['exp'] > self.now()
                    and type(claims.get('iat')) is int and claims['iat'] <= self.now() + 30, 'authentication_required')
            require(claims.get('aal') == 'aal2', 'mfa_required')
        except (ValueError, TypeError):
            raise OperatorError('authentication_required') from None
        self.subject, self.expires_at = user['id'], claims['exp']
        return self.subject

    def command(self, action, payload, request_id, idempotency_key):
        require(action in ACTIONS, 'unsupported_action')
        require(self.subject is not None and self.expires_at > self.now(), 'authentication_required')
        envelope = {'api_version': 'curated_catalog.v1', 'request_id': request_id,
                    'idempotency_key': idempotency_key, 'action': action, 'payload': payload}
        body = canonical(envelope)
        require(len(body) <= 32_768, 'request_too_large')
        response = self._send('POST', self.origin + '/functions/v1/curated-catalog-command', body,
                              {'Content-Type': 'application/json'})
        try:
            reply = parse_json(response.body)
            if response.status not in (200, 201):
                problem = reply.get('error') if isinstance(reply, dict) else None
                code = problem.get('code') if isinstance(problem, dict) else None
                raise OperatorError(code if isinstance(code, str) and code in ERROR_CODES else 'service_error', ambiguous=response.status >= 500)
            exact(reply, ['api_version', 'request_id', 'data'])
            require(reply['api_version'] == 'curated_catalog.v1' and reply['request_id'] == request_id)
            return self._data(action, reply['data'], payload)
        except OperatorError as error:
            if response.status not in (200, 201) and error.code in ERROR_CODES | {'service_error'}: raise
            raise OperatorError('invalid_service_response', ambiguous=True) from None

    def _data(self, action, raw, payload):
        require(isinstance(raw, dict))
        data = dict(raw)
        if 'replayed' in data: require(data.pop('replayed') is True)
        if action == 'accept_attestation':
            exact(data, ['document_kind', 'accepted_attestation_version', 'current_attestation_version'])
            require(data == {'document_kind': 'catalog_license_attestation', 'accepted_attestation_version': ATTESTATION_VERSION, 'current_attestation_version': ATTESTATION_VERSION})
            return data
        if action == 'create_upload':
            exact(data, ['upload_session_id', 'revision', 'expires_at', 'upload_endpoint', 'required_headers', 'scoped_upload_token'])
            identifier(data['upload_session_id']); integer(data['revision'], 1); text(data['expires_at'], 40)
            validate_upload_url(data['upload_endpoint'], self.origin)
            require(data['required_headers'] == {'Tus-Resumable': '1.0.0'} and data['scoped_upload_token'] == self.token)
            del data['scoped_upload_token']
            return data
        if action == 'status':
            exact(data, ['upload_session_id', 'revision', 'upload_state', 'expires_at', 'submission'])
            require(data['upload_session_id'] == payload['upload_session_id'])
            integer(data['revision'], 1); text(data['expires_at'], 40)
            require(data['upload_state'] in {'issued', 'uploading', 'completed', 'expired', 'cancelled'})
            if data['submission'] is not None:
                submission = dict(exact(data['submission'], ['submission_id', 'revision', 'generation', 'state', 'processing']))
                self._submission(submission)
                progress = submission['processing']
                exact(progress, ['submission_id', 'revision', 'generation', 'state', 'progress', 'safe_error_code', 'media_facts', 'generated_variants', 'duplicate_warning', 'suggestions', 'findings'])
                require(all(progress[key] == submission[key] for key in ('submission_id', 'revision', 'generation', 'state')))
                require(progress['progress'] is None or (type(progress['progress']) in (int, float) and 0 <= progress['progress'] <= 1))
                code = progress['safe_error_code']
                require(code is None or (isinstance(code, str) and re.fullmatch(r'WALI_[A-Z0-9_]{2,96}', code) is not None))
                # Persist only the bounded fields needed to operate this item.
                submission['processing'] = {'progress': progress['progress'], 'safe_error_code': code}
                data['submission'] = submission
            return data
        extra = ['processing_status_key'] if action == 'complete_upload' else ['field_errors'] if action in ('withdraw', 'save_draft') else []
        exact(data, ['submission_id', 'revision', 'generation', 'state', *extra])
        self._submission(data)
        if action != 'complete_upload': require(data['submission_id'] == payload['submission_id'])
        if action == 'complete_upload':
            require(data['state'] == 'processing' and data['processing_status_key'] == data['submission_id'] + ':' + str(data['generation']))
        elif action == 'submit':
            require(data['state'] == 'submitted' and data['generation'] == payload['expected_generation'])
        elif action == 'withdraw': require(data['state'] == 'withdrawn' and data['field_errors'] == [])
        elif action == 'save_draft': require(data['field_errors'] == [])
        return data

    @staticmethod
    def _submission(data):
        identifier(data['submission_id']); integer(data['revision'], 1); integer(data['generation'], 1)
        require(data['state'] in STATES)

    def tus_head(self, endpoint, expected_size):
        validate_upload_url(endpoint, self.origin)
        response = self._send('HEAD', endpoint, extra_headers={'Tus-Resumable': '1.0.0'}, maximum=1024)
        require(response.status in (200, 204) and response.headers.get('tus-resumable') == '1.0.0', 'invalid_upload_status')
        require(self._offset(response.headers.get('upload-length')) == expected_size, 'upload_length_changed')
        offset = self._offset(response.headers.get('upload-offset'))
        require(offset <= expected_size, 'invalid_upload_offset')
        return offset

    def tus_patch(self, endpoint, offset, data):
        validate_upload_url(endpoint, self.origin)
        require(1 <= len(data) <= CHUNK_BYTES, 'invalid_upload_chunk')
        response = self._send('PATCH', endpoint, data, {'Tus-Resumable': '1.0.0',
            'Content-Type': 'application/offset+octet-stream', 'Upload-Offset': str(offset)}, maximum=1024)
        if response.status != 204 or response.headers.get('tus-resumable') != '1.0.0':
            raise OperatorError('upload_patch_unconfirmed', ambiguous=True)
        confirmed = self._offset(response.headers.get('upload-offset'))
        require(confirmed == offset + len(data), 'invalid_upload_offset')
        return confirmed

    @staticmethod
    def _offset(value):
        require(isinstance(value, str) and re.fullmatch(r'0|[1-9][0-9]{0,10}', value) is not None, 'invalid_upload_offset')
        return integer(int(value), 0, MAX_FILE_BYTES)


class ReceiptStore:
    def __init__(self, directory, subject, item_id, fingerprint):
        directory = checked_path(directory, directory=True, may_not_exist=True)
        directory.mkdir(mode=0o700, exist_ok=True)
        require(directory.stat().st_uid == os.getuid() and stat.S_IMODE(directory.stat().st_mode) & 0o077 == 0, 'receipt_directory_not_private')
        self.path = directory / (identifier(item_id) + '.json')
        self.lock_fd = os.open(directory / (item_id + '.lock'), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.lock_fd)
            raise OperatorError('operation_in_progress') from None
        try:
            self.identity = {'schema': 'wali.curated_catalog.receipt.v1', 'project_ref': PRODUCTION_PROJECT,
                             'subject': identifier(subject), 'item_id': item_id, 'item_fingerprint': fingerprint}
            if self.path.exists():
                info = self.path.lstat()
                require(stat.S_IMODE(info.st_mode) & 0o077 == 0, 'receipt_not_private')
                self.value = read_local_json(self.path, 262_144)
                exact(self.value, [*self.identity, 'actions', 'upload_progress'])
                require(all(self.value[key] == value for key, value in self.identity.items()), 'receipt_identity_changed')
                require(isinstance(self.value['actions'], dict) and len(self.value['actions']) <= 64, 'invalid_receipt')
                self._validate_actions()
            else:
                self.value = {**self.identity, 'actions': {}, 'upload_progress': None}
                self.save()
        except BaseException:
            self.close()
            raise

    def _validate_actions(self):
        for key, record in self.value['actions'].items():
            exact(record, ['action', 'payload', 'request_id', 'idempotency_key', 'state', 'result', 'error'])
            require(record['action'] in ACTIONS and record['state'] in ('pending', 'succeeded', 'refused'), 'invalid_receipt')
            request_id, expected = operation_identity(self.identity['subject'], self.identity['item_id'], self.identity['item_fingerprint'], record['action'], record['payload'])
            require(key == expected == record['idempotency_key'] and request_id == record['request_id'], 'invalid_receipt')

    def save(self):
        raw = canonical(self.value) + b'\n'
        require(len(raw) <= 262_144, 'receipt_too_large')
        fd, name = tempfile.mkstemp(prefix='.curated-', dir=self.path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            os.replace(name, self.path)
            directory_fd = os.open(self.path.parent, os.O_RDONLY)
            try: os.fsync(directory_fd)
            finally: os.close(directory_fd)
        finally:
            if os.path.exists(name): os.unlink(name)

    def records(self, action, state):
        return [r for r in self.value['actions'].values() if r['action'] == action and r['state'] == state]

    def pending(self, action):
        records = self.records(action, 'pending')
        require(len(records) <= 1, 'pending_operation_requires_reconciliation')
        return records[0] if records else None

    def result(self, action, known=False):
        records = ([r for r in self.value['actions'].values() if r['action'] == action and r['result'] is not None]
                   if known else self.records(action, 'succeeded'))
        require(len(records) <= 1, 'operation_requires_reconciliation')
        return records[0]['result'] if records else None

    def call(self, client, action, payload):
        request_id, key = operation_identity(self.identity['subject'], self.identity['item_id'], self.identity['item_fingerprint'], action, payload)
        pending = self.pending(action)
        require(pending is None or pending['idempotency_key'] == key, 'pending_operation_requires_reconciliation')
        previous = self.value['actions'].get(key)
        previous_result = previous['result'] if previous else None
        record = {'action': action, 'payload': payload, 'request_id': request_id, 'idempotency_key': key,
                  'state': 'pending', 'result': previous_result, 'error': None}
        self.value['actions'][key] = record; self.save()
        try:
            result = client.command(action, payload, request_id, key)
            if action == 'create_upload' and previous and previous['result']:
                require(result['upload_session_id'] == previous['result']['upload_session_id']
                        and result['upload_endpoint'] == previous['result']['upload_endpoint'], 'upload_identity_changed')
        except OperatorError as error:
            record['state'] = 'pending' if error.ambiguous else 'refused'
            record['error'] = error.code; self.save()
            raise
        record.update(state='succeeded', result=result, error=None); self.save()
        return result

    def close(self):
        if self.lock_fd is not None:
            os.close(self.lock_fd); self.lock_fd = None
    def __enter__(self): return self
    def __exit__(self, *_): self.close()


class Operator:
    def __init__(self, client, receipt, item=None, media_root=None):
        self.client, self.receipt, self.item, self.media_root = client, receipt, item, media_root

    def accept(self):
        return self.receipt.call(self.client, 'accept_attestation', {'expected_subject_id': self.client.subject, 'attestation_version': ATTESTATION_VERSION})

    def status(self):
        reservation = self.receipt.result('create_upload', known=True)
        require(reservation is not None, 'upload_not_started')
        return self.receipt.call(self.client, 'status', {'upload_session_id': reservation['upload_session_id']})

    def upload(self):
        with FileSource(self.item, self.media_root) as source:
            pending = self.receipt.pending('complete_upload')
            if pending:
                return self.receipt.call(self.client, 'complete_upload', pending['payload'])
            if self.receipt.result('complete_upload'):
                return self.status()
            payload = {key: self.item[key] for key in ('container_hint', 'original_filename', 'target')}
            payload['declared_byte_count'] = self.item['byte_count']
            reservation = self.receipt.call(self.client, 'create_upload', payload)
            endpoint, session = reservation['upload_endpoint'], reservation['upload_session_id']
            try:
                expires = datetime.datetime.fromisoformat(reservation['expires_at'].replace('Z', '+00:00'))
                require(expires.tzinfo is not None and expires.timestamp() > self.client.now(), 'upload_expired')
            except ValueError:
                raise OperatorError('invalid_service_response', ambiguous=True) from None
            progress = self.receipt.value['upload_progress']
            if progress is None:
                progress = {'upload_session_id': session, 'confirmed_offset': 0, 'pending_patch': None}
                self.receipt.value['upload_progress'] = progress; self.receipt.save()
            exact(progress, ['upload_session_id', 'confirmed_offset', 'pending_patch'])
            require(progress['upload_session_id'] == session, 'upload_identity_changed')
            confirmed = integer(progress['confirmed_offset'], 0, source.size)
            offset = self.client.tus_head(endpoint, source.size)
            require(offset >= confirmed, 'upload_offset_regressed')
            patch = progress['pending_patch']
            if patch is None:
                require(offset == confirmed, 'unexplained_upload_offset')
            else:
                exact(patch, ['offset', 'byte_count', 'sha256'])
                require(patch['offset'] == confirmed and confirmed < source.size, 'invalid_receipt')
                expected = source.read(confirmed)
                require(len(expected) == patch['byte_count'] and digest(expected) == patch['sha256'], 'file_changed')
                require(offset <= confirmed + len(expected), 'unexplained_upload_offset')
            progress.update(confirmed_offset=offset, pending_patch=None); self.receipt.save()
            while offset < source.size:
                require(expires.timestamp() > self.client.now(), 'upload_expired')
                data = source.read(offset)
                progress['pending_patch'] = {'offset': offset, 'byte_count': len(data), 'sha256': digest(data)}
                self.receipt.save()
                offset = self.client.tus_patch(endpoint, offset, data)
                source.check()
                progress.update(confirmed_offset=offset, pending_patch=None); self.receipt.save()
            source.check()
            return self.receipt.call(self.client, 'complete_upload', {'upload_session_id': session,
                'expected_session_revision': reservation['revision'], 'draft': self.item['draft']})

    def save_draft(self):
        pending = self.receipt.pending('save_draft')
        if pending:
            # An ambiguous save must finish with its exact original revision
            # and draft before a later correction can become a new operation.
            return self.receipt.call(self.client, 'save_draft', pending['payload'])
        status_result = self.status()
        submission = status_result['submission']
        require(submission is not None, 'submission_not_ready')
        return self.receipt.call(self.client, 'save_draft', {'submission_id': submission['submission_id'],
            'expected_revision': submission['revision'], 'draft': self.item['draft']})

    def transition(self, action):
        require(action in ('submit', 'withdraw'), 'unsupported_action')
        pending = self.receipt.pending(action)
        if pending:
            return self.receipt.call(self.client, action, pending['payload'])
        status_result = self.status()
        submission = status_result['submission']
        require(submission is not None, 'submission_not_ready')
        if action == 'submit' and submission['state'] in ('submitted', 'under_review', 'approved', 'published'):
            return status_result
        if action == 'withdraw' and submission['state'] == 'withdrawn': return status_result
        if action == 'submit': require(submission['state'] == 'ready_for_submission', 'submission_not_ready')
        payload = {'submission_id': submission['submission_id'], 'expected_revision': submission['revision']}
        if action == 'submit': payload.update(expected_generation=submission['generation'], attestation_version=ATTESTATION_VERSION)
        return self.receipt.call(self.client, action, payload)


def read_token(fd):
    integer(fd, 0, 1024)
    mode = os.fstat(fd).st_mode
    require(stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode), 'token_requires_private_pipe')
    chunks = bytearray()
    deadline = time.monotonic() + 30
    while len(chunks) <= 8192:
        remaining = deadline - time.monotonic()
        require(remaining > 0 and bool(select.select([fd], [], [], max(0, remaining))[0]), 'token_pipe_timeout')
        chunk = os.read(fd, min(4096, 8193 - len(chunks)))
        if not chunk: break
        chunks.extend(chunk)
        if b'\n' in chunk: break
    require(len(chunks) <= 8192, 'invalid_access_token')
    try: token = bytes(chunks).decode('ascii').strip()
    except UnicodeError: raise OperatorError('invalid_access_token') from None
    require(re.fullmatch(r'[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', token) is not None, 'invalid_access_token')
    return token


def public_key_from_config(path):
    config = read_local_json(path, 65_536)
    settings = config.get('settings') if isinstance(config, dict) else None
    require(isinstance(settings, dict), 'invalid_public_configuration')
    project_origin(settings.get('WALI_SUPABASE_PROJECT_REF'))
    require(settings.get('WALI_SUPABASE_URL') == PRODUCTION_ORIGIN, 'wrong_project')
    value = settings.get('WALI_SUPABASE_PUBLISHABLE_KEY')
    require(isinstance(value, str) and 1 <= len(value) <= 8192, 'invalid_public_configuration')
    if not value.startswith('sb_publishable_'):
        try:
            part = value.split('.')[1]
            claims = parse_json(base64.urlsafe_b64decode(part + '=' * ((4-len(part) % 4) % 4)))
            require(claims.get('role') == 'anon', 'public_key_required')
        except (IndexError, ValueError, AttributeError):
            raise OperatorError('public_key_required') from None
    return value


class SafeParser(argparse.ArgumentParser):
    def error(self, _message): raise OperatorError('invalid_arguments')


def main(argv=None):
    parser = SafeParser(description=__doc__, epilog='The accept action records this declaration: ' + ATTESTATION_TEXT)
    parser.add_argument('action', choices=['validate', 'accept', 'upload', 'status', 'save-draft', 'submit', 'withdraw'])
    parser.add_argument('--project-ref', required=True)
    parser.add_argument('--config', type=Path, default=Path(__file__).resolve().parents[1] / 'Config/Marketplace.production.json')
    parser.add_argument('--token-fd', type=int, default=0, help='Private pipe descriptor; never a token value or file.')
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--media-root', type=Path)
    parser.add_argument('--item')
    parser.add_argument('--receipt-dir', type=Path)
    args = parser.parse_args(argv)
    project_origin(args.project_ref)
    item = None
    if args.action != 'accept':
        require(args.manifest is not None and args.media_root is not None and args.item is not None, 'manifest_item_required')
        item = load_manifest(args.manifest, args.media_root, identifier(args.item))
    if args.action == 'validate':
        with FileSource(item, args.media_root): pass
        print(json.dumps({'status': 'validated_offline', 'item_id': item['item_id'], 'byte_count': item['byte_count'], 'sha256': item['sha256']}))
        return 0
    require(args.receipt_dir is not None, 'receipt_directory_required')
    client = Client(args.project_ref, public_key_from_config(args.config), read_token(args.token_fd))
    client.authenticate()
    item_id = item['item_id'] if item else '00000000-0000-4000-8000-000000000000'
    fingerprint = item_fingerprint(item) if item else digest(canonical({'version': ATTESTATION_VERSION, 'text': ATTESTATION_TEXT}))
    with ReceiptStore(args.receipt_dir, client.subject, item_id, fingerprint) as receipt:
        operator = Operator(client, receipt, item, args.media_root)
        if args.action == 'accept': result = operator.accept()
        elif args.action == 'upload': result = operator.upload()
        elif args.action == 'status': result = operator.status()
        elif args.action == 'save-draft': result = operator.save_draft()
        else: result = operator.transition(args.action)
        submission = result.get('submission') or result
        print(json.dumps({'status': 'completed', 'action': args.action, 'item_id': item_id,
            'upload_session_id': result.get('upload_session_id'), 'submission_id': submission.get('submission_id'),
            'state': submission.get('state', result.get('upload_state')), 'receipt_path': str(receipt.path)}))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        code = error.code if isinstance(error, OperatorError) else 'operation_failed'
        print(json.dumps({'status': 'refused', 'code': code}), file=sys.stderr)
        sys.exit(1)
