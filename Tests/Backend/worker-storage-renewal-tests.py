#!/usr/bin/env python3
"""Real session_user tests in an explicitly disposable, local Supabase project.

No provider credentials are read. Setup and cleanup use ordinary nonsuperuser
postgres over the container's Unix socket. Issuance uses a newly created LOGIN
with a synthetic password over container-local loopback TCP and a synthetic Vault issuer.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime

SYNTHETIC_ISSUER = "fixture-only-" + "0" * 40
SYNTHETIC_LOGIN_PASSWORD = "local-fixture-only-" + "0" * 32


class FixtureError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise FixtureError(message)


def command(args, *, sql=None, timeout=30):
    return subprocess.run(
        args, input=sql, text=True, capture_output=True, timeout=timeout, check=False
    )


def checked(args):
    result = command(args)
    require(result.returncode == 0, "local Docker inspection failed")
    return result.stdout.strip()


def validate_target(project):
    require(
        project == "wali-release-ci-local"
        or (
            project == "wali-marketplace-local"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("CI") == "true"
            and os.environ.get("GITHUB_RUN_ID", "").isdigit()
        ),
        "use the disposable local test project; the default project is CI-only",
    )
    require(
        not os.environ.get("DOCKER_HOST")
        or os.environ["DOCKER_HOST"].startswith("unix:///"),
        "remote Docker endpoints are forbidden",
    )
    require(
        not os.environ.get("DOCKER_TLS_VERIFY") and not os.environ.get("DOCKER_CERT_PATH"),
        "remote Docker TLS configuration is forbidden",
    )
    endpoint = json.loads(
        checked(["docker", "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"])
    )
    require(endpoint.startswith("unix:///"), "Docker context must use a local Unix socket")
    container = "supabase_db_" + project
    details = json.loads(
        checked([
            "docker", "inspect", container, "--format",
            '{"Id":{{json .Id}},"State":{"Running":{{json .State.Running}}},'
            '"Config":{"Labels":{{json .Config.Labels}},"Image":{{json .Config.Image}}}}',
        ])
    )
    require(details["State"]["Running"], "test database is not running")
    require(
        details["Config"]["Labels"].get("com.supabase.cli.project") == project,
        "Supabase test-project label mismatch",
    )
    require(
        details["Config"]["Image"].startswith((
            "public.ecr.aws/supabase/postgres:",
            "ghcr.io/supabase/postgres:",
        )),
        "unexpected local test database image",
    )
    return details["Id"]


class RenewalFixture:
    def __init__(self, container):
        self.container = container
        suffix = uuid.uuid4().hex
        self.role = "wali_renewal_test_" + suffix
        self.worker = "renewal-test-" + suffix
        self.secret_name = "wali-renewal-test-" + suffix
        self.setup_started = False
        self.assertions = 0
        self.phase = "preflight"

    def sql(self, statement, *, role="postgres", expected_error=None):
        login_env = ["-e", "PGPASSWORD=" + SYNTHETIC_LOGIN_PASSWORD] if role == self.role else []
        result = command(
            [
                "docker", "exec", "-i", "-e", "PGOPTIONS=-c statement_timeout=15000 -c lock_timeout=5000",
                *login_env, self.container, "psql", "-X", "-qAt",
                "-h", "127.0.0.1" if role == self.role else "/var/run/postgresql", "-U", role, "-d", "postgres",
                "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=sqlstate",
            ],
            sql=statement,
        )
        if expected_error:
            require(
                result.returncode != 0
                and re.search(r"\b" + re.escape(expected_error) + r"\b", result.stderr),
                "expected restricted-login denial was not observed",
            )
            return ""
        # Never print database output: a successful issuance includes a token.
        code = re.search(r"ERROR:\s+([A-Z0-9]{5})\b", result.stderr)
        require(result.returncode == 0, f"local fixture SQL failed during {self.phase} (SQLSTATE {code.group(1) if code else 'unavailable'})")
        return result.stdout.strip()

    def check(self, condition, message):
        require(condition, message)
        self.assertions += 1

    def setup(self):
        identity = json.loads(self.sql("""
select json_build_object('user',session_user,'database',current_database(),
 'superuser',(select rolsuper from pg_roles where rolname=session_user),
 'table_owner',(select pg_get_userbyid(relowner) from pg_class where oid='wali.worker_storage_auth_bindings'::regclass),
 'function_owner',(select pg_get_userbyid(proowner) from pg_proc where oid='wali.renew_storage_worker_token()'::regprocedure),
 'binding_count',(select count(*) from wali.worker_storage_auth_bindings));
"""))
        require(
            identity == {
                "user": "postgres", "database": "postgres", "superuser": False,
                "table_owner": "postgres", "function_owner": "postgres", "binding_count": 0,
            },
            "fresh nonsuperuser-owned test database required",
        )
        absent = self.sql(f"""
select not exists(select 1 from pg_roles where rolname='{self.role}')
 and not exists(select 1 from vault.secrets where name='{self.secret_name}');
""")
        require(absent == "t", "synthetic fixture identity already exists")
        self.setup_started = True
        self.phase = "setup"
        self.sql(f"""
begin;
create role {self.role} login noinherit nosuperuser nocreatedb nocreaterole noreplication nobypassrls password '{SYNTHETIC_LOGIN_PASSWORD}';
grant wali_worker to {self.role};
insert into wali.worker_storage_auth_bindings(login_role_oid,login_role_name,worker_id,storage_origin,issuer_secret_id,enabled)
select oid,rolname,'{self.worker}','https://fixture.supabase.co',
 vault.create_secret('{SYNTHETIC_ISSUER}','{self.secret_name}'),true
from pg_roles where rolname='{self.role}';
commit;
""")

    def run(self):
        # New psql connection, not SET SESSION AUTHORIZATION or SET ROLE identity emulation.
        self.phase = "restricted login checks"
        actual_login = self.sql("select session_user;", role=self.role)
        self.check(actual_login == self.role, "fixture must authenticate as its restricted LOGIN")
        self.sql("select * from wali.renew_storage_worker_token();", role=self.role, expected_error="42501")
        self.check(True, "NOINHERIT requires explicit worker role")
        result = json.loads(self.sql(
            "set role wali_worker; select row_to_json(t) from wali.renew_storage_worker_token() t;",
            role=self.role,
        ))
        token = result["access_token"]
        parts = token.split(".")
        require(len(parts) == 3, "invalid synthetic issuance token")
        decode = lambda value: base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        header = json.loads(decode(parts[0]))
        claims = json.loads(decode(parts[1]))
        self.check(result["worker_id"] == self.worker, "worker identity must come from binding")
        expiry = datetime.fromisoformat(result["expires_at"]).timestamp()
        self.check(time.time() + 870 <= expiry <= time.time() + 900, "expiry must be bounded to fifteen minutes")
        self.check(header == {"alg": "HS256", "typ": "JWT"}, "fixed HS256 header required")
        self.check(set(claims) == {"aud", "exp", "iat", "iss", "role", "worker_id"}, "claims must remain narrow")
        self.check(
            claims["role"] == "wali_storage_worker" and claims["aud"] == "authenticated"
            and claims["iss"] == "https://fixture.supabase.co/auth/v1"
            and claims["worker_id"] == self.worker,
            "issuer must bind fixed Storage claims",
        )
        self.check(claims["exp"] - claims["iat"] == 900 and claims["exp"] == expiry, "caller cannot extend lifetime")
        expected = hmac.new(SYNTHETIC_ISSUER.encode(), (parts[0] + "." + parts[1]).encode(), hashlib.sha256).digest()
        self.check(hmac.compare_digest(decode(parts[2]), expected), "signature must cover exact claims with synthetic issuer")
        self.sql(f"update wali.worker_storage_auth_bindings set enabled=false where login_role_name='{self.role}';")
        self.denied("disabled binding must refuse issuance")
        self.sql(f"update wali.worker_storage_auth_bindings set enabled=true,login_role_oid=0 where login_role_name='{self.role}';")
        self.denied("stale role OID must refuse issuance")
        self.sql(f"""
update wali.worker_storage_auth_bindings set login_role_oid=(select oid from pg_roles where rolname='{self.role}') where login_role_name='{self.role}';
alter role {self.role} inherit;
""")
        self.denied("broadened login privilege must refuse issuance")

    def denied(self, message):
        self.sql("set role wali_worker; select * from wali.renew_storage_worker_token();", role=self.role, expected_error="P0001")
        self.check(True, message)

    def cleanup(self):
        if not self.setup_started:
            return
        self.phase = "cleanup"
        # Names are generated once and proved absent before setup; never delete
        # unrelated bindings, secrets, roles, databases, containers, or volumes.
        self.sql(f"""
begin;
delete from wali.worker_storage_auth_bindings where login_role_name='{self.role}' and worker_id='{self.worker}';
delete from vault.secrets where name='{self.secret_name}';
drop role if exists {self.role};
commit;
""")
        remaining = self.sql(f"""
select exists(select 1 from pg_roles where rolname='{self.role}')
 or exists(select 1 from wali.worker_storage_auth_bindings where login_role_name='{self.role}')
 or exists(select 1 from vault.secrets where name='{self.secret_name}');
""")
        require(remaining == "f", "synthetic fixture cleanup incomplete")
        self.setup_started = False


def exercise(fixture):
    try:
        fixture.setup()
        fixture.run()
    finally:
        # One interruption must still permit the bounded cleanup commands.
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            fixture.cleanup()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


def interrupted(_signum, _frame):
    raise FixtureError("local fixture interrupted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-id", required=True)
    args = parser.parse_args()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    fixture = RenewalFixture(validate_target(args.project_id))
    exercise(fixture)
    print(f"Worker Storage renewal: {fixture.assertions} real-login checks passed; synthetic fixtures removed")


if __name__ == "__main__":
    try:
        main()
    except (FixtureError, subprocess.SubprocessError, ValueError, KeyError) as error:
        # Details can include SQL output in third-party exception messages.
        detail = str(error) if isinstance(error, FixtureError) else type(error).__name__
        print(f"Worker Storage renewal test failed: {detail}; no credentials printed", file=sys.stderr)
        sys.exit(1)
