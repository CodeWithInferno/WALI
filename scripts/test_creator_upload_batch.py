"""Offline ordinary Creator client tests. No network, DB, secret, or live media use."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('ordinary_operator', Path(__file__).with_name('creator-upload-batch.py'))
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
fixture_spec = importlib.util.spec_from_file_location('curated_fixtures', Path(__file__).with_name('test_curated_catalog.py'))
fixture = importlib.util.module_from_spec(fixture_spec)
fixture_spec.loader.exec_module(fixture)
fixture.cli = cli.common

class Server(fixture.FakeServer):
    def __init__(self, size):
        super().__init__(size)
        self.ordinary_requests = []
        self.confirmed = True
    def send(self, method, url, headers, body, maximum_bytes):
        self.ordinary_requests.append((method, url, body))
        if url.endswith('/auth/v1/user'):
            return cli.common.HTTPResponse(self.auth_status, {}, json.dumps({'id': fixture.SUBJECT,
                'email': 'fixture@example.invalid', 'email_confirmed_at': '2030-01-01T00:00:00Z' if self.confirmed else None,
                'is_anonymous': False}).encode())
        if '/functions/v1/' in url:
            original = json.loads(body)
            action = {'create-upload':'create_upload', 'complete-upload':'complete_upload'}[url.rsplit('/',1)[1]]
            assert original['api_version'] == 'creator.v1'
            assert 'action' not in original and 'payload' not in original
            mapped = {'api_version': 'curated_catalog.v1', 'request_id': original['request_id'],
                'idempotency_key': original['idempotency_key'], 'action': action,
                'payload': {k:v for k,v in original.items() if k not in ('api_version','request_id','idempotency_key')}}
            result = super().send(method, cli.common.PRODUCTION_ORIGIN + '/functions/v1/curated-catalog-command', headers,
                                  json.dumps(mapped).encode(), maximum_bytes)
            document = json.loads(result.body)
            if 'api_version' in document: document['api_version'] = 'creator.v1'
            return cli.common.HTTPResponse(result.status, result.headers, json.dumps(document).encode())
        if url.endswith('/rest/v1/rpc/creator_processing_status_v1'):
            payload = json.loads(body)
            return cli.common.HTTPResponse(200, {}, json.dumps({'submission_id':payload['submission_id'],
              'generation':payload['generation'],'revision':self.revision,'state':self.state,'progress':0.5,
              'safe_error_code':None,'media_facts':None,'generated_variants':[],'duplicate_warning':False,
              'suggestions':[],'findings':[]}).encode())
        return super().send(method,url,headers,body,maximum_bytes)

class CreatorUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wali-ordinary-unit-',dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.media = self.root/'media';self.media.mkdir(mode=0o700)
        self.source = self.media/'fixture.mp4';self.source.write_bytes(b'bounded fixture bytes')
        self.item = {'item_id':fixture.ITEM,'file_path':str(self.source),
          'sha256':cli.common.digest(self.source.read_bytes()),'byte_count':self.source.stat().st_size,
          'container_hint':'video/mp4','original_filename':'fixture.mp4','target':{'kind':'new'},
          'draft':{'title':'Original credited title','description':'A synthetic test.',
            'primary_category_id':fixture.CATEGORY,'suggested_tag_ids':[],'content_warning':None,
            'rights_basis':'licensed','rights_holder':'Original artist','license_id':fixture.CATEGORY,
            'source_url':'https://source.example.invalid/work','attribution_text':'Original Artist; Wallsflow.',
            'proof_object_ids':[],'attests_rights':True,'creator_terms_version':'2026-09-12'}}
        self.server=Server(self.item['byte_count'])
        self.client=cli.Client(cli.common.PRODUCTION_PROJECT,'sb_publishable_fixture',fixture.fixture_token(aal='aal1'),
                               self.server,now=lambda:fixture.NOW)
        self.client.authenticate(fixture.SUBJECT)
    def tearDown(self): self.temp.cleanup()
    def receipt(self, item=None):
        return cli.ReceiptStore(self.root/'receipts',fixture.SUBJECT,fixture.ITEM,cli.item_fingerprint(item or self.item))
    def upload(self):
        with self.receipt() as receipt:return cli.Operator(self.client,receipt,self.item,self.media).upload()
    def test_real_auth_accepted_aal1_is_sufficient_without_terms_mutation(self):
        self.assertEqual(self.client.subject,fixture.SUBJECT)
        self.assertEqual(len(self.server.ordinary_requests),1)
    def test_unverified_email_refused_before_upload(self):
        self.server.confirmed=False
        with self.assertRaises(cli.OperatorError):self.client.authenticate(fixture.SUBJECT)
        self.assertEqual(len(self.server.commands),0)
    def test_expected_owner_switch_refused_before_upload(self):
        with self.assertRaises(cli.OperatorError):self.client.authenticate(fixture.ITEM)
        self.assertEqual(len(self.server.commands),0)
    def test_auth_server_rejection_cannot_be_overridden_by_jwt_claims(self):
        self.server.auth_status=401
        with self.assertRaises(cli.OperatorError):self.client.authenticate(fixture.SUBJECT)
    def test_metadata_precedes_processing_and_credentials_do_not_enter_receipt(self):
        self.assertEqual(self.upload()['state'],'processing')
        complete=[json.loads(body) for _,url,body in self.server.ordinary_requests if url.endswith('/complete-upload')][0]
        self.assertEqual(complete['draft'],self.item['draft'])
        self.assertNotIn('attestation_version',complete['draft'])
        self.assertEqual(bytes(self.server.uploaded),self.source.read_bytes())
        with self.receipt() as receipt:
            self.assertEqual(receipt.identity['schema'],'wali.creator_upload.receipt.v1')
            self.assertNotIn(self.client.token,receipt.path.read_text())
        self.assertFalse(any('curated-catalog-command' in url or 'publish' in url or 'creator-command' in url for _,url,_ in self.server.ordinary_requests))
    def test_lost_completion_replays_exact_draft_and_operation(self):
        self.server.fail_complete_once=True
        with self.assertRaises(cli.OperatorError):self.upload()
        self.assertEqual(self.upload()['state'],'processing')
        attempts=[json.loads(body) for _,url,body in self.server.ordinary_requests if url.endswith('/complete-upload')]
        self.assertEqual(attempts[0],attempts[1]);self.assertEqual(self.server.new_sessions,1)
    def test_ambiguous_patch_resumes_from_confirmed_head_without_duplicate_bytes(self):
        self.server.fail_patch_once=True
        with self.assertRaises(cli.OperatorError):self.upload()
        self.upload();self.assertEqual(bytes(self.server.uploaded),self.source.read_bytes())
        self.assertEqual(self.server.new_sessions,1)
    def test_changed_metadata_cannot_reuse_an_existing_receipt(self):
        self.upload()
        changed={**self.item,'draft':{**self.item['draft'],'title':'Changed'}}
        with self.assertRaises(cli.OperatorError):
            with self.receipt(changed):pass
    def test_cross_origin_tus_is_refused(self):
        self.server.create_overrides={'upload_endpoint':'https://evil.invalid/storage/v1/upload/resumable/a'}
        with self.assertRaises(cli.OperatorError):self.upload()
        self.assertEqual(len(self.server.uploaded),0)
    def test_terms_review_and_publication_commands_are_not_exposed(self):
        for action in ('accept_terms','accept_attestation','submit','publish','retry_publication'):
            with self.assertRaises(cli.OperatorError):self.client.command(action,{},fixture.ITEM,'a'*16)
        self.assertEqual(len(self.server.commands),0)
    def test_status_uses_owner_scoped_reader_and_retains_safe_state(self):
        self.upload();self.server.state='published'
        self.assertEqual(self.upload()['state'],'published')
        self.assertTrue(any(url.endswith('/creator_processing_status_v1') for _,url,_ in self.server.ordinary_requests))
    def test_conversion_preserves_all_licensed_fields_and_file_identity(self):
        old={**self.item,'draft':{**self.item['draft']}}
        old['draft']['attestation_version']=old['draft'].pop('creator_terms_version')
        source=self.root/'curated.json';source.write_text(json.dumps({'schema':'wali.curated_catalog.batch.v1',
            'project_ref':cli.common.PRODUCTION_PROJECT,'items':[old]}))
        out=self.root/'creator.json';cli.convert_manifest(source,self.media,out)
        new=cli.load_manifest(out,self.media)
        self.assertEqual(new,[self.item])
        self.assertEqual(out.stat().st_mode & 0o777,0o600)
    def test_backpressure_preserves_same_reservation_identity(self):
        self.server.error_code='processing_capacity_unavailable';self.server.error_status=503
        with self.assertRaises(cli.OperatorError):self.upload()
        first=json.loads(self.server.ordinary_requests[-1][2])
        self.server.error_code=None
        self.upload()
        second=[json.loads(body) for _,url,body in self.server.ordinary_requests if url.endswith('/create-upload')][1]
        self.assertEqual(first,second);self.assertEqual(self.server.new_sessions,1)

if __name__=='__main__':unittest.main()
