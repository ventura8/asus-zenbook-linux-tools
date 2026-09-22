---
name: sonarqube
description: >-
  Run SonarQube analysis for this repo — locally against a throwaway Docker
  server, or by reading the CI job's results — and triage findings. Use when
  asked to scan the code, check the quality gate, fix Sonar issues, or change
  sonar-project.properties / the CI sonarqube job.
---

# SonarQube

SonarQube Cloud analyses this repo in CI (`sonarqube` job in
[`.github/workflows/ci.yml`](../../../.github/workflows/ci.yml)); configuration
lives in [`sonar-project.properties`](../../../sonar-project.properties).
For iteration, scan locally against a disposable server — never point a local
experiment at the shared Cloud project.

## Coverage contract (read before touching report paths)

Sonar consumes what the pipeline already produces. Two different formats:

| Language | Property | File | Produced by |
| --- | --- | --- | --- |
| Python | `sonar.python.coverage.reportPaths` | `reports/coverage/merged/coverage.xml` | `_write_merged_python_coverage_xml` |
| Shell | `sonar.coverageReportPaths` | `reports/coverage/merged/shell-coverage.xml` | `_write_sonar_generic_shell_coverage` |

Python takes Cobertura directly; shell goes through
`scripts/coverage/cobertura_to_sonar_generic.py`. Both writers live in
`scripts/coverage/gates_python.sh`.

**`sonar.coverageReportPaths` accepts only SonarQube's own generic coverage
XML — never Cobertura.** Handing it kcov's `cobertura.xml` fails the scan with
`Error during parsing of the generic coverage report`. That is why the
converter exists; keep both writers in `scripts/coverage/gates_python.sh`
best-effort so a report failure never turns a passing gate into a red pipeline.
`tests/unit/shell/test_pipeline_ci_parity.py` guards these paths — update it in
the same change set when they move.

## Local scan (throwaway server)

```bash
docker run -d --name asus-sonar-local -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true sonarqube:community
# Wait for {"status":"UP"} (roughly a minute):
curl -s http://localhost:9000/api/system/status
```

Set an admin password and mint a token (local throwaway instance only — never
reuse a Cloud token here, and never commit either):

```bash
NEW="$(python3 -c 'import secrets;print("L"+secrets.token_urlsafe(18)+"9!")')"
curl -s -u admin:admin -X POST http://localhost:9000/api/users/change_password \
  -d "login=admin&previousPassword=admin&password=$NEW"
TOKEN="$(curl -s -u "admin:$NEW" -X POST \
  http://localhost:9000/api/user_tokens/generate -d 'name=local-scan' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')"
```

Generate coverage first when coverage numbers matter (otherwise the scan still
runs and only reports issues):

```bash
ASUS_COVERAGE_MODE=kcov ./scripts/run_docker_matrix.sh --coverage-gate
python3 scripts/coverage/cobertura_to_sonar_generic.py \
  reports/kcov/coverage-gate-kcov-all/kcov-merged/cobertura.xml \
  reports/coverage/merged/shell-coverage.xml
```

Scan (`sonar.organization` is Cloud-only, so blank it for the local server):

```bash
docker run --rm --network host -e SONAR_HOST_URL=http://localhost:9000 \
  -e SONAR_TOKEN="$TOKEN" -v "$PWD:/usr/src" sonarsource/sonar-scanner-cli \
  -Dsonar.projectKey=asus-local -Dsonar.organization=
```

List findings (the UI is at <http://localhost:9000>):

```bash
curl -s -u "$TOKEN:" \
  "http://localhost:9000/api/issues/search?componentKeys=asus-local&ps=500&resolved=false" \
  | python3 -c 'import sys,json
d = json.load(sys.stdin)
print(d["total"])
for i in d["issues"]:
    where = i["component"].split(":", 1)[-1] + ":" + str(i.get("line", "-"))
    print(i["severity"], i["type"], where, i["message"])'
```

Tear down when finished: `docker rm -f asus-sonar-local`.

## CI plumbing traps (both of these failed a real scan)

1. **`upload-artifact` strips the common ancestor.** With both reports under
   `reports/coverage/merged/`, the artifact holds them at its *root*, so the
   download must use `path: reports/coverage/merged` — not `path: reports`.
   Change one report path and the ancestor moves; re-check the download path.
2. **Generic-coverage report paths must exist.** A missing
   `sonar.coverageReportPaths` file fails the whole scan with a parse error
   (the Python sensor merely warns). The job checks both files and blanks the
   property with a `::warning::` when one is absent, so analysis still
   publishes after an upstream coverage-gate failure.
3. **The merged kcov tree is a temp dir.** `merge_kcov_coverage_shards` builds
   it under `mktemp -d` and removes it; the host merge never writes
   `reports/kcov/<slug>/` (that layout exists only in the Docker coverage-gate
   flow). Convert from the merged tree inside the merge, before the cleanup.

## Triage rules

1. **Verify every finding against the code before changing anything.** Sonar
   rules are heuristics; a rule firing is not proof of a defect.
2. Fix order: `BUG` → product-code `CODE_SMELL` → test-code smells.
3. **Do not weaken a test to silence a rule.** A fixture that must pass (for
   example a case under `@unittest.expectedFailure`) keeps its behaviour; make
   the assertion non-tautological instead of deleting it.
4. Skip, with the reason stated to the user, when the rule misreads intent —
   e.g. "always return tuples of the same length" on a helper whose tuple is a
   variable-length sequence (singular vs plural msgid), or a `monkeypatch`
   suggestion inside a `unittest.TestCase` that already restores state in
   `finally`.
5. **Never add suppression comments** (`# NOSONAR`, `noqa`, `nosec`,
   `eslint-disable`). `scripts/check_no_lint_suppressions.py` fails the lint
   gate on them; fix the code or leave the finding with a stated reason.
6. After fixing, re-run the repo's own gates — `scripts/run-lints.sh` and the
   affected unit suites — before re-scanning. Sonar is additional to those
   gates, never a replacement.

## CI job

The `sonarqube` job needs `coverage-merge`, downloads the
`coverage-merged-reports` artifact, checks out with `fetch-depth: 0` (new-code
attribution), passes `sonar.projectVersion` from the root `VERSION`, and uses
`secrets.SONAR_TOKEN`. It is skipped on fork PRs, where the token is not
exposed, and still runs when a coverage gate fails so findings stay visible.
Pin the scan action by commit SHA with a trailing `# vX.Y.Z` comment, matching
every other action pin in this repo.
