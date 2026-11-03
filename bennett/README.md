# Bennett Legal layer

This fork builds the production DocuSeal image for Bennett Legal's retainer signing. The branch `bennett-legal` is upstream DocuSeal plus a few normal commits (`bennett/NOTICE.md` lists them), and this folder. Infrastructure (the gateway, the host stack, AWS) lives in the firm's private repository.

## Layout

| Path | What it is |
|---|---|
| `Dockerfile.bennett`, `docker-bake.hcl` | The production image: upstream's own `Dockerfile`, unmodified, then this layer |
| `launch.rb`, `source_check.rb` | Container entry point. Refuses to start if a Bennett change is missing or the database, queue or keys are misconfigured |
| `puma.rb`, `storage.yml` | Upstream Puma config with a configurable bind; private cache metadata for stored objects |
| `rds-global-bundle.pem`, `ca-provenance.json` | Public AWS RDS trust anchors |
| `NOTICE.md` | Modification and source notice, shipped in the image |
| `test/` | Bennett tests: `ruby bennett/test/run.rb`, plus `node bennett/test/branding_layout.test.cjs` (Playwright) |
| `ci/` | The nightly pipeline's scripts and the production-mode smoke test |

## Build locally

```sh
echo "3.3.5+bennett.local" > .version
docker buildx bake -f bennett/docker-bake.hcl --load      # bennett-docuseal:local, linux/amd64
ruby bennett/test/run.rb
```

## Nightly pipeline

`.github/workflows/bennett-nightly.yml` runs at 07:00 UTC and on demand (`gh workflow run bennett-nightly.yml --ref bennett-legal`). The `verify` job, which has no write access to the repository:

1. Merges upstream `docusealco/docuseal` `master` into a work copy of `bennett-legal`. On a conflict, or if upstream changed workflow files, it stops and opens or updates one issue labelled `upstream-merge`.
2. Runs the Bennett tests and the browser layout test.
3. Builds the image for linux/amd64 and scans it with Trivy. It fails on any CRITICAL finding that `ci/trivyignore.yaml` does not explicitly accept (each entry is scoped and expires).
4. Runs `ci/run-smoke.sh`: postgres, valkey, the new image and the production gateway image (pulled from ECR by digest), configured like production (non-root, read-only, no capabilities, internal data network). It bootstraps a synthetic account the way the host's `bootstrap.rb` does, then acts as JUD, a visitor and two signers (`ci/smoke.mjs`):
   - every DocuSeal API call JUD makes, with JUD's headers and the checks JUD applies to the answers (template representation, PDF bytes, clone, submission fields, external-ID lookup, invite, expiry);
   - the practice-stamp `PUT /api/templates/:id` and its re-read;
   - the gateway's refusals and headers, and the signer assets it serves;
   - a Spanish client and an attorney signing in headless Chromium through the gateway, including the email codes, the recipient-order patch refusing the attorney's early write, the signed PDF with its digital signature, the audit log, the signed webhooks and the signed-copy email.
5. Publishes only if all of that passed, from `bennett-legal`, with the AWS role: it pushes the tested image to ECR as `bl-<commit>`. The `publish` job then pushes the merge to `bennett-legal` (fast-forward only) and tags the same digest `verified-<yyyymmdd>-<commit>` in ECR and in git.

A commit that already has a verified image is rebuilt every night but republished only once a week, for current Alpine packages. Without the AWS role the run still merges, tests, builds, scans and smoke-tests, but with the edge talking to DocuSeal directly (no gateway checks), and publishes nothing.

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (default `us-east-1`), `ECR_REPOSITORY` (`<account>.dkr.ecr.<region>.amazonaws.com/bennett-docuseal`) and `GATEWAY_IMAGE` (the production gateway, `…/bennett-docuseal-gateway@sha256:…`). Update `GATEWAY_IMAGE` whenever production's gateway changes.

The production server deploys the newest `verified-*` image with `host.py update` (in the private repository), which backs up first and rolls back on a failed health check.

## When the nightly stops

- **Merge issue:** merge by hand as the issue says, run the tests, push. The next passing run closes the issue.
- **Tests:** `source_check.rb` failing means a merge lost a Bennett change; `test_storage.rb` failing means upstream changed `config/storage.yml` (carry the change into `bennett/storage.yml`).
- **Smoke test:** the artifact `smoke-test-<run>` has `results.json`, screenshots and the stack's logs. `template representation matches the pinned one` failing means DocuSeal now returns templates differently than the version JUD enrolled its templates on; every approved template's pinned hash in JUD (`LIVE_TEMPLATE_DRIFT`) would drift, so update JUD before `ci/expected/template-projection.json`. The pinned file was recorded from the production image (`bennett-docuseal@sha256:e2dc9ab7…`, DocuSeal 3.3.4) on 2026-11-03.
- **Trivy:** take the fix (often it is already in the next upstream release), or add a scoped, expiring entry to `ci/trivyignore.yaml` with the reason.
