#!/usr/bin/env python3
"""Bounded ordinary Creator uploads for an already licensed batch; no consent or publication commands."""
import base64
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import uuid

# Reuse reviewed filesystem, bounded TUS transport, and response-shape helpers.
# The staff client, its AAL2 check, policy constants and CLI remain unchanged.
_spec = importlib.util.spec_from_file_location('wali_curated_upload_helpers', Path(__file__).with_name('curated-catalog.py'))
common = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(common)
OperatorError = common.OperatorError
require, exact, identifier, integer, text = common.require, common.exact, common.identifier, common.integer, common.text
canonical, digest, parse_json = common.canonical, common.digest, common.parse_json
checked_path, read_local_json, https_url = common.checked_path, common.read_local_json, common.https_url
project_origin, validate_upload_url = common.project_origin, common.validate_upload_url
PRODUCTION_PROJECT, PRODUCTION_ORIGIN = common.PRODUCTION_PROJECT, common.PRODUCTION_ORIGIN
MAX_FILE_BYTES = common.MAX_FILE_BYTES
CREATOR_TERMS_VERSION = '2026-09-12'
ACTIONS = {'create_upload', 'complete_upload'}
ERROR_CODES = common.ERROR_CODES | {'verified_email_required','creator_role_required','creator_terms_required',
    'upload_quota_exceeded','upload_size_exceeded','upload_target_invalid','upload_already_bound',
    'metadata_incomplete','rights_workflow_unavailable','upload_draft_required'}


def item_fingerprint(item):
    # Completion metadata is part of this batch's frozen identity, not a mutable correction path.
    return digest(canonical(item))


def operation_identity(subject, item_id, fingerprint, action, payload):
    require(action in ACTIONS, 'unsupported_action')
    identity = digest(canonical({'project_ref':PRODUCTION_PROJECT,'subject':identifier(subject),
        'item_id':identifier(item_id),'item_fingerprint':fingerprint,'action':action,'payload':payload}))
    return str(uuid.uuid5(uuid.NAMESPACE_URL,'wali.creator.v1:'+identity)), 'cu_'+identity[:60]

def validate_draft(value):
    exact(value, ['title', 'description', 'primary_category_id', 'suggested_tag_ids', 'content_warning',
        'rights_basis', 'rights_holder', 'license_id', 'source_url', 'attribution_text', 'proof_object_ids',
        'attests_rights', 'creator_terms_version'])
    text(value['title'], 120); text(value['description'], 2000)
    identifier(value['primary_category_id']); identifier(value['license_id'])
    tags = value['suggested_tag_ids']
    require(isinstance(tags, list) and len(tags) <= 20)
    for tag in tags: identifier(tag)
    require(len(set(tags)) == len(tags))
    if value['content_warning'] is not None: text(value['content_warning'], 500)
    require(value['rights_basis'] == 'licensed' and value['proof_object_ids'] == []
            and value['attests_rights'] is True and value['creator_terms_version'] == CREATOR_TERMS_VERSION)
    text(value['rights_holder'], 160); text(value['attribution_text'], 500); https_url(value['source_url'])
    return value


def load_manifest(path, media_root, item_id=None):
    root = checked_path(media_root, directory=True)
    manifest = read_local_json(path, 262_144)
    exact(manifest, ['schema', 'project_ref', 'items'])
    require(manifest['schema'] == 'wali.creator_upload.batch.v1')
    project_origin(manifest['project_ref'])
    items = manifest['items']
    require(isinstance(items, list) and 1 <= len(items) <= 24, 'invalid_batch_size')
    ids, paths, selected = set(), set(), []
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
        if item_id is None or current_id == item_id: selected.append(item)
    require(bool(selected), 'item_not_found')
    return selected


def convert_manifest(path, media_root, output):
    document = read_local_json(path,262_144)
    exact(document,['schema','project_ref','items'])
    require(document['schema']=='wali.curated_catalog.batch.v1')
    project_origin(document['project_ref'])
    require(isinstance(document['items'],list) and 1<=len(document['items'])<=24,'invalid_batch_size')
    converted=[]
    for raw in document['items']:
        item=common.load_manifest(path,media_root,identifier(raw.get('item_id')))
        draft=dict(item['draft'])
        draft['creator_terms_version']=draft.pop('attestation_version')
        converted.append({**item,'draft':draft})
    body=canonical({'schema':'wali.creator_upload.batch.v1','project_ref':PRODUCTION_PROJECT,'items':converted})+b'\n'
    destination=checked_path(output,may_not_exist=True)
    if destination.exists():
        require(destination.read_bytes()==body,'output_already_exists')
    else:
        fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as stream:stream.write(body);stream.flush();os.fsync(stream.fileno())
    load_manifest(destination,media_root)
    return {'status':'converted_offline','count':len(converted),'manifest_sha256':digest(body),'manifest_path':str(destination)}


class Client(common.Client):
    def _send(self,method,url,body=None,extra_headers=None,maximum=65_536):
        allowed={self.origin+'/auth/v1/user',self.origin+'/functions/v1/create-upload',
                 self.origin+'/functions/v1/complete-upload',self.origin+'/rest/v1/rpc/creator_processing_status_v1'}
        if url not in allowed:validate_upload_url(url,self.origin)
        if url!=self.origin+'/auth/v1/user':
            require(self.subject is not None and self.expires_at>self.now(),'authentication_required')
        headers={'Authorization':'Bearer '+self.token,'apikey':self.publishable_key}
        headers.update(extra_headers or {})
        response=self.transport.send(method,url,headers,body,maximum)
        if 300<=response.status<400:raise OperatorError('redirect_refused',ambiguous=True)
        if len(response.body)>maximum:raise OperatorError('response_too_large',ambiguous=True)
        return response

    def authenticate(self,expected_subject):
        expected_subject=identifier(expected_subject)
        self.subject,self.expires_at=None,0
        response=self._send('GET',self.origin+'/auth/v1/user')
        require(response.status==200,'authentication_required')
        user=parse_json(response.body)
        require(isinstance(user,dict) and user.get('id')==expected_subject,'authentication_required')
        require(isinstance(user.get('email'),str) and bool(user['email'])
                and isinstance(user.get('email_confirmed_at'),str) and bool(user['email_confirmed_at'])
                and user.get('is_anonymous') is False,'verified_email_required')
        # Claims are considered only after Auth accepted this exact token and subject.
        try:
            part=self.token.split('.')[1]
            claims=parse_json(base64.urlsafe_b64decode(part+'='*((4-len(part)%4)%4)))
            require(isinstance(claims,dict) and identifier(claims.get('sub'))==expected_subject,'authentication_required')
            require(claims.get('iss')==self.origin+'/auth/v1' and claims.get('aud') in ('authenticated',['authenticated'])
                    and claims.get('role')=='authenticated' and claims.get('aal') in ('aal1','aal2'),'authentication_required')
            require(type(claims.get('exp')) is int and claims['exp']>self.now()
                    and type(claims.get('iat')) is int and claims['iat']<=self.now()+30,'authentication_required')
        except (ValueError,TypeError):raise OperatorError('authentication_required') from None
        self.subject,self.expires_at=expected_subject,claims['exp']
        return self.subject

    def command(self,action,payload,request_id,idempotency_key):
        require(action in ACTIONS,'unsupported_action')
        envelope={'api_version':'creator.v1','request_id':request_id,'idempotency_key':idempotency_key,**payload}
        require(set(payload).isdisjoint({'api_version','request_id','idempotency_key'}),'invalid_input')
        if action=='complete_upload':
            exact(payload,['upload_session_id','expected_session_revision','draft']);validate_draft(payload['draft'])
        body=canonical(envelope);require(len(body)<=32_768,'request_too_large')
        response=self._send('POST',self.origin+'/functions/v1/'+action.replace('_','-'),body,{'Content-Type':'application/json'})
        try:
            reply=parse_json(response.body)
            if response.status not in (200,201):
                problem=reply.get('error') if isinstance(reply,dict) else None
                code=problem.get('code') if isinstance(problem,dict) else None
                raise OperatorError(code if code in ERROR_CODES else 'service_error',ambiguous=response.status>=500)
            exact(reply,['api_version','request_id','data'])
            require(reply['api_version']=='creator.v1' and reply['request_id']==request_id)
            return self._data(action,reply['data'],payload)
        except OperatorError as error:
            if response.status not in (200,201) and error.code in ERROR_CODES|{'service_error'}:raise
            raise OperatorError('invalid_service_response',ambiguous=True) from None

    def processing_status(self,completion):
        payload={'submission_id':identifier(completion['submission_id']),'generation':integer(completion['generation'],1)}
        response=self._send('POST',self.origin+'/rest/v1/rpc/creator_processing_status_v1',canonical(payload),{'Content-Type':'application/json'})
        require(response.status==200,'status_unavailable')
        value=parse_json(response.body)
        require(isinstance(value,dict) and value.get('submission_id')==payload['submission_id']
                and value.get('generation')==payload['generation'],'invalid_service_response')
        self._submission(value)
        code=value.get('safe_error_code')
        require(code is None or (isinstance(code,str) and re.fullmatch(r'WALI_[A-Z0-9_]{2,96}',code) is not None),'invalid_service_response')
        return {k:value[k] for k in ('submission_id','revision','generation','state')}|{'safe_error_code':code}

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
            self.identity = {'schema': 'wali.creator_upload.receipt.v1', 'project_ref': PRODUCTION_PROJECT,
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
        fd, name = tempfile.mkstemp(prefix='.creator-', dir=self.path.parent)
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
    def __init__(self,client,receipt,item,media_root):
        self.client,self.receipt,self.item,self.media_root=client,receipt,item,media_root

    # This method only uses FileSource, HEAD/PATCH, receipt calls and the supplied
    # create/complete client. It contains no staff admission or publication action.
    upload=common.Operator.upload

    def status(self):
        completion=self.receipt.result('complete_upload',known=True)
        require(completion is not None,'upload_not_completed')
        return self.client.processing_status(completion)


def main(argv=None):
    parser=common.SafeParser(description=__doc__)
    parser.add_argument('action',choices=['convert','validate','upload','status'])
    parser.add_argument('--project-ref',required=True)
    parser.add_argument('--manifest',type=Path,required=True)
    parser.add_argument('--media-root',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--item')
    parser.add_argument('--exclude-item',action='append',default=[],help='A known item already uploaded through the native app; no synthetic receipt is created.')
    parser.add_argument('--expected-subject')
    parser.add_argument('--config',type=Path,default=Path(__file__).resolve().parents[1]/'Config/Marketplace.production.json')
    parser.add_argument('--token-fd',type=int,default=0,help='Private pipe descriptor; never a token value or file.')
    parser.add_argument('--receipt-dir',type=Path)
    parser.add_argument('--wait-seconds',type=int,default=0,help='Bounded wait on server processing capacity,0..3600 seconds.')
    args=parser.parse_args(argv)
    project_origin(args.project_ref);integer(args.wait_seconds,0,3600)
    if args.action=='convert':
        require(args.output is not None,'output_required')
        print(json.dumps(convert_manifest(args.manifest,args.media_root,args.output)));return 0
    items=load_manifest(args.manifest,args.media_root,identifier(args.item) if args.item else None)
    excluded={identifier(value) for value in args.exclude_item}
    require(excluded.issubset({item['item_id'] for item in items}),'item_not_found')
    items=[item for item in items if item['item_id'] not in excluded]
    require(bool(items),'empty_batch')
    if args.action=='validate':
        for item in items:
            with common.FileSource(item,args.media_root):pass
        print(json.dumps({'status':'validated_offline','count':len(items),
                          'manifest_sha256':digest(Path(args.manifest).read_bytes()),'total_bytes':sum(i['byte_count'] for i in items)}));return 0
    require(args.receipt_dir is not None and args.expected_subject is not None,'receipt_and_subject_required')
    client=Client(args.project_ref,common.public_key_from_config(args.config),common.read_token(args.token_fd))
    client.authenticate(identifier(args.expected_subject))
    deadline=time.monotonic()+args.wait_seconds
    completed=0
    for item in items:
        with ReceiptStore(args.receipt_dir,client.subject,item['item_id'],item_fingerprint(item)) as receipt:
            operator=Operator(client,receipt,item,args.media_root)
            while True:
                try:
                    result=operator.upload() if args.action=='upload' else operator.status()
                    break
                except OperatorError as error:
                    if error.code!='processing_capacity_unavailable' or time.monotonic()>=deadline:raise
                    # No new key or reservation is created while waiting for real capacity.
                    time.sleep(min(30,max(0,deadline-time.monotonic())))
            completed+=1
            print(json.dumps({'status':'observed','action':args.action,'item_id':item['item_id'],
                'submission_id':result.get('submission_id'),'state':result.get('state'),
                'safe_error_code':result.get('safe_error_code'),'receipt_path':str(receipt.path)}),flush=True)
    print(json.dumps({'status':'batch_complete','action':args.action,'count':completed}));return 0


if __name__=='__main__':
    try:sys.exit(main())
    except Exception as error:
        code=error.code if isinstance(error,OperatorError) else 'operation_failed'
        print(json.dumps({'status':'refused','code':code}),file=sys.stderr);sys.exit(1)
