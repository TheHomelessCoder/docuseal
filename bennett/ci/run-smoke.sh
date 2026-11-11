#!/usr/bin/env bash
# Production-mode smoke test of a Bennett DocuSeal image.
#
#   bennett/ci/run-smoke.sh DOCUSEAL_IMAGE [GATEWAY_IMAGE]
#
# With a gateway image, every request goes through the real gateway, as in
# production. Without one (before the AWS role exists) the edge stand-in talks
# to DocuSeal directly and the gateway checks are reported as skipped.
#
# Needs docker compose, openssl, and node with `npm ci` done in bennett/ci and
# Playwright's Chromium installed. Settings, keys and passwords are synthetic
# and made fresh for every run; they stay in $SMOKE_DIR, never in out/.
# Results and screenshots: $SMOKE_DIR/out. SMOKE_KEEP=1 leaves the stack up.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=${1:?usage: run-smoke.sh DOCUSEAL_IMAGE [GATEWAY_IMAGE]}
gateway=${2:-}
SMOKE_DIR=${SMOKE_DIR:-$(mktemp -d)}
export SMOKE_DIR
mkdir -p "$SMOKE_DIR/out" "$SMOKE_DIR/tls"
chmod 700 "$SMOKE_DIR"
if [ -n "$gateway" ]; then mode=gateway; else mode=direct; fi
compose=(docker compose -p bennett-smoke -f "$here/compose.yaml" -f "$here/compose.$mode.yaml" --env-file "$SMOKE_DIR/stack.env")
step() { printf '\n== %s (%s)\n' "$1" "$(date -u +%H:%M:%SZ)"; }
hex() { openssl rand -hex "$1"; }

cleanup() {
  status=$?
  if [ "$status" -ne 0 ] || [ "${SMOKE_KEEP:-}" = 1 ]; then
    "${compose[@]}" ps -a > "$SMOKE_DIR/out/containers.txt" 2>&1 || true
    # DocuSeal's own output is suppressed by launch.rb; these are launcher
    # events, health and the stand-ins. No values from stack.env appear here.
    "${compose[@]}" logs --no-color --timestamps > "$SMOKE_DIR/out/compose.log" 2>&1 || true
  fi
  [ "${SMOKE_KEEP:-}" = 1 ] || "${compose[@]}" down -v --remove-orphans > /dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT

step "synthetic settings, keys and certificates ($mode mode)"
(
  umask 077
  cat > "$SMOKE_DIR/stack.env" <<EOF
DOCUSEAL_IMAGE=$image
GATEWAY_IMAGE=${gateway:-none}
SMOKE_DIR=$SMOKE_DIR
SIGNING_HOST=sign.ci.test
STAFF_HOST=sign-staff.ci.test
API_HOST=sign-api.ci.test
CF_ACCESS_TEAM=ci-team
CF_ACCESS_AUD=$(hex 32)
CF_API_ACCESS_AUD=$(hex 32)
CI_ACCESS_CLIENT_ID=$(hex 16).access
CI_ACCESS_CLIENT_SECRET=$(hex 32)
DOCUSEAL_DB_PASSWORD=$(hex 32)
DOCUSEAL_REDIS_PASSWORD=$(hex 32)
DOCUSEAL_SECRET_KEY_BASE=$(hex 64)
DOCUSEAL_ENCRYPTION_SECRET=$(hex 32)
DOCUSEAL_SMTP_PASSWORD=$(hex 16)
CI_WEBHOOK_SECRET=whsec_$(openssl rand -base64 24 | tr '+/' '-_')
EOF
)
setting() { sed -n "s/^$1=//p" "$SMOKE_DIR/stack.env"; }
tls=$SMOKE_DIR/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Bennett smoke-test CA' -keyout "$tls/ca.key" -out "$tls/ca.pem" \
  -addext 'basicConstraints=critical,CA:true' -addext 'keyUsage=critical,keyCertSign,cRLSign' 2> /dev/null
openssl req -newkey rsa:2048 -nodes -subj '/CN=sign.ci.test' -keyout "$tls/tls.key" -out "$tls/tls.csr" 2> /dev/null
printf 'subjectAltName=DNS:sign.ci.test,DNS:sign-staff.ci.test,DNS:sign-api.ci.test,DNS:ci-team.cloudflareaccess.com,DNS:mailpit\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > "$tls/ext.cnf"
openssl x509 -req -in "$tls/tls.csr" -CA "$tls/ca.pem" -CAkey "$tls/ca.key" -CAcreateserial -days 2 -extfile "$tls/ext.cnf" -out "$tls/tls.crt" 2> /dev/null
rm -f "$tls/ca.key" "$tls/ca.srl" "$tls/tls.csr" "$tls/ext.cnf"
# Throwaway keys for this run only; the mail and edge stand-ins run as other users.
chmod 755 "$tls" && chmod 644 "$tls"/*
echo "settings: $(sed 's/=.*//' "$SMOKE_DIR/stack.env" | tr '\n' ' ')"

step "start the stack (production mode; only the CI stand-ins publish ports)"
"${compose[@]}" config --quiet
"${compose[@]}" up -d --wait --wait-timeout 900
"${compose[@]}" ps --format 'table {{.Service}}\t{{.Status}}'

rails_runner() { # rails_runner SCRIPT [-e NAME ...]: runs bennett/ci/rails/SCRIPT, prints its JSON line
  local script=$1
  shift
  # As host.py bootstrap does: values travel only in the exec's environment.
  docker exec -i -w /app "$@" "$("${compose[@]}" ps -q docuseal)" \
    sh -c 'REDIS_URL="redis://default:${REDIS_PASSWORD}@${REDIS_HOST}:6379/0" exec bin/rails runner -' \
    < "$here/rails/$script" > "$SMOKE_DIR/out/$script.log" 2>&1
  grep '^{' "$SMOKE_DIR/out/$script.log" | tail -1
}

step "bootstrap the account as host.py bootstrap does (synthetic)"
api_token=$(hex 32)
DOCUSEAL_BOOTSTRAP_JSON=$(printf '{"account_name":"Bennett Legal (smoke test)","timezone":"Central Time (US & Canada)","first_name":"Smoke","last_name":"Admin","email":"admin@example.test","password":"%s","app_url":"https://sign.ci.test","api_token":"%s"}' "$(hex 24)" "$api_token")
export DOCUSEAL_BOOTSTRAP_JSON
bootstrap=$(rails_runner bootstrap.rb -e DOCUSEAL_BOOTSTRAP_JSON)
unset DOCUSEAL_BOOTSTRAP_JSON
echo "$bootstrap"
echo "$bootstrap" | grep -q '"setup":"done"'

step "verify staff authentication with real signatures and Rails sessions"
docker exec -i -w /app "$("${compose[@]}" ps -q docuseal)" \
  bundle exec ruby -r ./lib/bennett/staff_access - < "$here/../test/staff_access.rb"
staff_access=$(rails_runner staff_access.rb)
echo "$staff_access"
echo "$staff_access" | grep -q '"staff_access":"passed"'

step "verify serialized email images and plain-text/PDF parts (no delivery)"
mail_assets=$(rails_runner mail_assets.rb)
echo "$mail_assets"
echo "$mail_assets" | grep -q '"mail_assets":"passed"'

step "verify staff JUD context and recipient isolation in signing emails (no delivery)"
jud_email_context=$(rails_runner jud_email_context.rb)
echo "$jud_email_context"
echo "$jud_email_context" | grep -q '"jud_email_context":"passed"'

step "verify per-agreement document ID headers in generated previews and results"
document_reference=$(rails_runner document_reference.rb)
echo "$document_reference"
echo "$document_reference" | grep -q '"document_reference":"passed"'
for language in en es; do
  for kind in preview result; do
    docker exec "$("${compose[@]}" ps -q docuseal)" cat "/tmp/bennett-reference-$language-$kind.pdf" \
      > "$SMOKE_DIR/out/bennett-reference-$language-$kind.pdf"
  done
done

step "seed the synthetic retainer template, import draft and JUD webhook"
CI_WEBHOOK_URL=http://jud:8090/webhooks/docuseal CI_WEBHOOK_SECRET=$(setting CI_WEBHOOK_SECRET)
export CI_WEBHOOK_URL CI_WEBHOOK_SECRET
seed=$(rails_runner seed.rb -e CI_WEBHOOK_URL -e CI_WEBHOOK_SECRET)
unset CI_WEBHOOK_SECRET
echo "$seed"

MODE=$mode SEED=$seed API_TOKEN=$api_token ACCESS_ID=$(setting CI_ACCESS_CLIENT_ID) ACCESS_SECRET=$(setting CI_ACCESS_CLIENT_SECRET) node -e '
  const seed = JSON.parse(process.env.SEED);
  const run = { mode: process.env.MODE, signHost: "sign.ci.test", apiHost: "sign-api.ci.test", staffHost: "sign-staff.ci.test",
    apiToken: process.env.API_TOKEN, accessClientId: process.env.ACCESS_ID, accessClientSecret: process.env.ACCESS_SECRET,
    templateId: seed.template_id, draftId: seed.draft_id, documentSha256: seed.document_sha256, pages: seed.pages };
  require("node:fs").writeFileSync(process.env.SMOKE_DIR + "/run.json", JSON.stringify(run), { mode: 0o600 });'

step "act as JUD, the gateway's visitors and both signers"
set +e
node "$here/smoke.mjs"
smoke=$?
set -e

if [ "$smoke" -eq 0 ]; then
  step "verify actual unsigned, signed and audit PDFs from all four private-link browser flows"
  CI_RETAINER_FLOW_EVIDENCE=$(cat "$SMOKE_DIR/out/jud-retainer-flows.json")
  export CI_RETAINER_FLOW_EVIDENCE
  retainer_flow_evidence=$(rails_runner retainer_flow_evidence.rb -e CI_RETAINER_FLOW_EVIDENCE)
  unset CI_RETAINER_FLOW_EVIDENCE
  echo "$retainer_flow_evidence"
  echo "$retainer_flow_evidence" | grep -q '"retainer_flow_evidence":"passed"'
  step "verify all final digital seals independently with Poppler/NSS"
  mkdir -m 700 "$SMOKE_DIR/nssdb"
  certutil -N -d "sql:$SMOKE_DIR/nssdb" --empty-password
  for language in en es; do
    for device in desktop mobile; do
      evidence="$SMOKE_DIR/out/private-link-$language-$device-signature.txt"
      # Trust is checked against the exact CI root by the Rails fixture above;
      # NSS independently checks the CMS signature and complete byte range.
      pdfsig -nssdir "$SMOKE_DIR/nssdb" -nocert -no-ocsp \
        "$SMOKE_DIR/out/private-link-$language-$device-signed.pdf" > "$evidence" 2>&1
      grep -q 'Signature Validation: Signature is Valid\.' "$evidence"
      grep -q 'Total document signed' "$evidence"
    done
  done
fi

step "container posture"
posture=0
services='postgres valkey docuseal'
[ "$mode" = gateway ] && services="$services gateway"
for service in $services; do
  id=$("${compose[@]}" ps -q "$service")
  [ -n "$id" ] || { echo "$service: missing -> FAIL" | tee -a "$SMOKE_DIR/out/posture.txt"; posture=1; continue; }
  line=$(docker inspect --format '{{.Config.User}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.CapDrop}}|{{.HostConfig.SecurityOpt}}|{{.State.Health.Status}}' "$id")
  IFS='|' read -r user readonly capdrop secopt health <<< "$line"
  verdict=ok
  case "$user" in '' | 0 | 0:* | root | root:*) verdict="FAIL runs as root" ;; esac
  [ "$readonly" = true ] || verdict="FAIL writable root filesystem"
  [ "$capdrop" = '[ALL]' ] || verdict="FAIL capabilities kept"
  case "$secopt" in *no-new-privileges:true*) ;; *) verdict="FAIL privilege escalation allowed" ;; esac
  [ "$health" = healthy ] || verdict="FAIL health $health"
  echo "$service: user=$user read_only=$readonly cap_drop=$capdrop health=$health -> $verdict" | tee -a "$SMOKE_DIR/out/posture.txt"
  case "$verdict" in FAIL*) posture=1 ;; esac
done
image_user=$(docker image inspect --format '{{.Config.User}}' "$image")
revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")
echo "image: user=$image_user revision=$revision" | tee -a "$SMOKE_DIR/out/posture.txt"
[ "$image_user" = 2000:2000 ] || posture=1
events=$("${compose[@]}" logs --no-color docuseal 2>&1 | grep -o '"event":"[a-z_]*"' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')
echo "launcher events: $events" | tee -a "$SMOKE_DIR/out/posture.txt"
case "$events" in *'"event":"starting"'*) ;; *) posture=1 ;; esac
case "$events" in *rejected*) posture=1 ;; esac

# shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
node -e '
  const fs = require("node:fs"); const out = process.env.SMOKE_DIR + "/out";
  const r = JSON.parse(fs.readFileSync(out + "/results.json", "utf8"));
  const rows = r.results.map(c => `| ${c.skipped ? "skipped" : c.ok ? "pass" : "**FAIL**"} | ${c.name.replace(/\|/g, "/")} |`);
  fs.writeFileSync(out + "/summary.md", `### Smoke test (${r.mode} mode): ${r.passed} passed, ${r.failed} failed, ${r.seconds} s\n\n| Result | Check |\n|---|---|\n${rows.join("\n")}\n\n` +
    "```\n" + fs.readFileSync(out + "/posture.txt", "utf8") + "```\n");' || true
[ "$smoke" -eq 0 ] && [ "$posture" -eq 0 ]
