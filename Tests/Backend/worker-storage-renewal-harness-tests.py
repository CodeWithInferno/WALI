#!/usr/bin/env python3
"""Credential-free checks of local target rejection and unconditional cleanup."""

import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

MODULE = Path(__file__).with_name("worker-storage-renewal-tests.py")
SPEC = importlib.util.spec_from_file_location("worker_renewal_fixture", MODULE)
renewal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(renewal)


class FakeFixture:
    def __init__(self, failure=None):
        self.failure = failure
        self.events = []

    def setup(self):
        self.events.append("setup")
        if self.failure == "setup":
            raise renewal.FixtureError("setup interrupted")

    def run(self):
        self.events.append("run")
        if self.failure == "run":
            raise renewal.FixtureError("issuance assertion failed")

    def cleanup(self):
        self.events.append("cleanup")
        if self.failure == "cleanup":
            raise renewal.FixtureError("cleanup failed")


class HarnessTests(unittest.TestCase):
    def test_success_cleans_up(self):
        fixture = FakeFixture()
        renewal.exercise(fixture)
        self.assertEqual(fixture.events, ["setup", "run", "cleanup"])

    def test_assertion_failure_cleans_up(self):
        fixture = FakeFixture("run")
        with self.assertRaises(renewal.FixtureError):
            renewal.exercise(fixture)
        self.assertEqual(fixture.events, ["setup", "run", "cleanup"])

    def test_partial_setup_failure_cleans_up(self):
        fixture = FakeFixture("setup")
        with self.assertRaises(renewal.FixtureError):
            renewal.exercise(fixture)
        self.assertEqual(fixture.events, ["setup", "cleanup"])

    def test_cleanup_failure_is_not_success(self):
        with self.assertRaises(renewal.FixtureError):
            renewal.exercise(FakeFixture("cleanup"))

    @patch.dict(os.environ, {}, clear=True)
    @patch.object(renewal, "checked")
    def test_normal_dev_project_refused_before_docker(self, checked):
        with self.assertRaises(renewal.FixtureError):
            renewal.validate_target("wali-marketplace-local")
        checked.assert_not_called()

    @patch.dict(os.environ, {"DOCKER_HOST": "tcp://example.invalid:2375"}, clear=True)
    @patch.object(renewal, "checked")
    def test_remote_docker_refused_before_connecting(self, checked):
        with self.assertRaises(renewal.FixtureError):
            renewal.validate_target("wali-release-ci-local")
        checked.assert_not_called()

    @patch.dict(os.environ, {}, clear=True)
    @patch.object(renewal, "checked", return_value='"ssh://example.invalid"')
    def test_remote_context_refused_before_container_inspection(self, checked):
        with self.assertRaises(renewal.FixtureError):
            renewal.validate_target("wali-release-ci-local")
        self.assertEqual(checked.call_count, 1)


    @patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "CI": "true", "GITHUB_RUN_ID": "1"}, clear=True)
    def test_ci_accepts_supabase_cli_official_database_mirrors(self):
        for registry in ["public.ecr.aws", "ghcr.io"]:
            with self.subTest(registry=registry):
                details = {
                    "Id": "synthetic-container-id", "State": {"Running": True},
                    "Config": {"Labels": {"com.supabase.cli.project": "wali-marketplace-local"},
                               "Image": registry + "/supabase/postgres:17.6.1.165"},
                }
                with patch.object(renewal, "checked", side_effect=[
                    '"unix:///var/run/docker.sock"', json.dumps(details)
                ]):
                    self.assertEqual(renewal.validate_target("wali-marketplace-local"), "synthetic-container-id")

    @patch.dict(os.environ, {}, clear=True)
    def test_foreign_and_lookalike_database_images_remain_rejected(self):
        for image in ["example.invalid/supabase/postgres:17.6.1.165",
                      "ghcr.io.example.invalid/supabase/postgres:17.6.1.165",
                      "ghcr.io/supabase/postgres-other:17.6.1.165"]:
            with self.subTest(image=image):
                details = {
                    "Id": "synthetic-container-id", "State": {"Running": True},
                    "Config": {"Labels": {"com.supabase.cli.project": "wali-release-ci-local"},
                               "Image": image},
                }
                with patch.object(renewal, "checked", side_effect=[
                    '"unix:///var/run/docker.sock"', json.dumps(details)
                ]):
                    with self.assertRaises(renewal.FixtureError):
                        renewal.validate_target("wali-release-ci-local")

    @patch.dict(os.environ, {}, clear=True)
    def test_official_image_does_not_bypass_project_label(self):
        details = {
            "Id": "synthetic-container-id", "State": {"Running": True},
            "Config": {"Labels": {"com.supabase.cli.project": "another-project"},
                       "Image": "ghcr.io/supabase/postgres:17.6.1.165"},
        }
        with patch.object(renewal, "checked", side_effect=[
            '"unix:///var/run/docker.sock"', json.dumps(details)
        ]):
            with self.assertRaises(renewal.FixtureError):
                renewal.validate_target("wali-release-ci-local")

if __name__ == "__main__":
    unittest.main()
