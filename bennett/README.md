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
| `test/` | Bennett tests: `ruby bennett/test/run.rb`, `node --test bennett/test/mail_assets.test.mjs`, plus `node bennett/test/branding_layout.test.cjs` (Playwright) |
| `ci/` | The nightly pipeline's scripts and the production-mode smoke test |

## Staff sign-in

The staff workspace can use the same Cloudflare Access email-code login type as JUD, with no second DocuSeal password for an account without native authenticator verification. This is an explicit host deployment selection:

```sh
BENNETT_STAFF_ACCESS_ENABLED=true
BENNETT_STAFF_ACCESS_HOST=sign-staff.bennettlegal.com
BENNETT_STAFF_ACCESS_TEAM=bennettlaw
BENNETT_STAFF_ACCESS_AUD=<the staff application's 64-character audience tag>
```

The gateway must forward only the assertion it has verified for the staff host. Rails independently verifies RS256 signatures against the fixed team's HTTPS certificate endpoint, issuer, staff audience, expiry, issued-at, human email and application-token type. Native administration requires a matching existing active user and account. Account permissions and lockouts remain authoritative; no user is automatically created. A configured native authenticator still requires its existing password and code. Cookies or an asserted email header alone cannot grant staff access. Sign-out clears the native session and goes to Cloudflare's logout endpoint. Incomplete enabled configuration fails at boot. With the selection off, upstream authentication remains available.

Every active Bennett Legal JUD user can review signing documents and audit history at `https://jud.bennettlegal.com/retainers`. An Access-authenticated staff viewer without a native account is sent there for JUD's own active-account authorization. No separate native account is needed for viewing, and no native editing permissions are created. The Access application uses JUD's managed staff group while retaining its own twelve-hour session lifetime.

For an existing active native account, email verification at `/sign_in` opens `/submissions`. The staff header links to **JUD retainers**, **All submissions**, **Completed**, templates and settings. Submission details and event timelines use the same staff theme; frame/modal responses retain their existing behavior. Appearance can follow the system or use light/dark mode. DocuSeal's logo and attribution remain visible.

Validation includes `bundle exec ruby bennett/test/staff_access.rb` (real RSA/JWT checks), `node bennett/test/staff_layout.test.cjs` (the real navbar ERB and theme assets at mobile/desktop widths), and `bennett/ci/rails/staff_access.rb` in the production-mode smoke stack. The latter checks actual Rails/Devise sessions, CSRF, logout, revoked users and the authenticator flow inside a rolled-back synthetic transaction. No real email or document is used.

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
   - a Spanish client and an attorney signing in headless Chromium through the gateway, including the email codes, the recipient-order patch refusing the attorney's early write, the signed PDF with its digital signature, the audit log, the signed webhooks and the signed-copy email;
   - every email it receives: the intake nurture letterhead in light mode, dark mode and Outlook's dark mode (painted in the browser, with a dark screenshot saved), DocuSeal's attribution, and a plain-text part that starts with the eyebrow rather than the stylesheet. The logo and social icons are inline MIME attachments from `public/packs/bennett-mail-*.png`; no remote image download is required. Before rendering, the test retrieves the actual Mailpit parts, checks their bytes against that artwork, and confirms every image loads with networking blocked. A separate Rails check serializes and reparses 14 mail types, including English/Spanish invitations and copies, OTP, staff and account messages, without delivering them. These checks do not replace verification in an actual Outlook inbox.
5. Publishes only if all of that passed, from `bennett-legal`, with the AWS role: it pushes the tested image to ECR as `bl-<commit>`. The `publish` job then pushes the merge to `bennett-legal` (fast-forward only) and tags the same digest `verified-<yyyymmdd>-<commit>` in ECR and in git.

A commit that already has a verified image is rebuilt every night but republished only once a week, for current Alpine packages. Without the AWS role the run still merges, tests, builds, scans and smoke-tests, but with the edge talking to DocuSeal directly (no gateway checks), and publishes nothing.

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (default `us-east-1`), `ECR_REPOSITORY` (`<account>.dkr.ecr.<region>.amazonaws.com/bennett-docuseal`) and `GATEWAY_IMAGE` (the production gateway, `…/bennett-docuseal-gateway@sha256:…`). Update `GATEWAY_IMAGE` whenever production's gateway changes.

The production server deploys the newest `verified-*` image with `host.py update` (in the private repository), which backs up first and rolls back on a failed health check.

## When the nightly stops

- **Merge issue:** merge by hand as the issue says, run the tests, push. The next passing run closes the issue.
- **Tests:** `source_check.rb` failing means a merge lost a Bennett change; `test_storage.rb` failing means upstream changed `config/storage.yml` (carry the change into `bennett/storage.yml`).
- **Smoke test:** the artifact `smoke-test-<run>` has `results.json`, screenshots and the stack's logs. `template representation matches the pinned one` failing means DocuSeal now returns templates differently than the version JUD enrolled its templates on; every approved template's pinned hash in JUD (`LIVE_TEMPLATE_DRIFT`) would drift, so update JUD before `ci/expected/template-projection.json`. The pinned file was recorded from the production image (`bennett-docuseal@sha256:e2dc9ab7…`, DocuSeal 3.3.4) on 2026-11-03.
- **Trivy:** take the fix (often it is already in the next upstream release), or add a scoped, expiring entry to `ci/trivyignore.yaml` with the reason.
