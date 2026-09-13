#!/usr/bin/env python3
"""Synthetic --dry-run only. No real keys or host/service operations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
REPO=Path(__file__).resolve().parents[2]
class StorageAuthDeployTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='wali-auth-mode-');self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
  for name,value in [('worker','fixture'),('key','fixture'),('media','a'*64),('verifier','b'*64)]: (self.root/name).write_text(value)
  self.base='''WALI_DEPLOY_ENVIRONMENT=staging
WALI_SUPABASE_PROJECT_REF=abcdefghijklmnopqrst
WALI_DATABASE_URL=postgresql://worker:fixture@db.abcdefghijklmnopqrst.supabase.co/postgres?sslmode=verify-full
WALI_STORAGE_URL=https://abcdefghijklmnopqrst.supabase.co
WALI_STORAGE_PUBLISHABLE_KEY=sb_publishable_fixture
WALI_MEDIA_IMAGE=registry.test/media@sha256:'''+ 'a'*64 + '\nWALI_VERIFIER_IMAGE=registry.test/verifier@sha256:'+'b'*64+'\nWALI_CLASSIFIER_IMAGE=\n'
  self.args=[str(REPO/'deploy/worker/deploy.sh'),'--dry-run','--environment','staging','--supabase-project-ref','abcdefghijklmnopqrst','--worker-binary',str(self.root/'worker'),'--environment-file',str(self.root/'env'),'--media-sbom',str(self.root/'media'),'--verifier-sbom',str(self.root/'verifier'),'--cosign-key',str(self.root/'key')]
 def invoke(self,extra):
  (self.root/'env').write_text(self.base+extra)
  result=subprocess.run(self.args,text=True,capture_output=True,env={k:v for k,v in os.environ.items() if k not in ('BASH_ENV','ENV')})
  self.assertNotIn('PRIVATE_VALUE',result.stdout+result.stderr)
  return result
 def test_database_renewal_without_static_token(self): self.assertEqual(self.invoke('WALI_STORAGE_AUTH_MODE=database_renewal\n').returncode,0)
 def test_legacy_static_preview_stays_supported(self): self.assertEqual(self.invoke('WALI_STORAGE_WORKER_TOKEN=fixture.header.signature\n').returncode,0)
 def test_mixed_unknown_and_duplicate_modes_fail(self):
  for extra in ['WALI_STORAGE_AUTH_MODE=unknown\n','WALI_STORAGE_AUTH_MODE=database_renewal\nWALI_STORAGE_WORKER_TOKEN=PRIVATE_VALUE\n','WALI_STORAGE_AUTH_MODE=database_renewal\nWALI_STORAGE_AUTH_MODE=static\n','WALI_STORAGE_AUTH_MODE=database_renewal\nWALI_STORAGE_WORKER_TOKEN=\nWALI_STORAGE_WORKER_TOKEN=\n']:
   with self.subTest(extra=extra.splitlines()[0]): self.assertNotEqual(self.invoke(extra).returncode,0)
if __name__=='__main__': unittest.main()
