#!/usr/bin/env bash
# Scan the built image with Trivy, from a saved tarball (the scanner never
# gets the Docker socket). Fails on any CRITICAL finding that trivyignore.yaml
# does not explicitly accept. Report: $SCAN_DIR (trivy.json, trivy.txt, summary.md).
#   bennett/ci/scan.sh IMAGE
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=${1:?usage: scan.sh IMAGE}
trivy=${TRIVY_IMAGE:-aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c}
dir=${SCAN_DIR:-$(mktemp -d)}
mkdir -p "$dir"
docker save "$image" -o "$dir/image.tar"
cp "$here/trivyignore.yaml" "$dir/trivyignore.yaml"
run() { docker run --rm -v "$dir:/scan" -v bennett-trivy-cache:/root/.cache/trivy "$trivy" image --input /scan/image.tar --scanners vuln "$@"; }

# Every severity, for the record (no ignore file: accepted findings stay visible).
run --format json --output /scan/trivy.json --quiet
run --skip-db-update --format table --output /scan/trivy.txt --quiet
# The gate.
set +e
run --skip-db-update --severity CRITICAL --exit-code 1 --ignorefile /scan/trivyignore.yaml --format table --output /scan/critical.txt --quiet
gate=$?
set -e

libexpat=$(docker run --rm --entrypoint apk "$image" info -e -v libexpat 2> /dev/null || echo 'not installed')
# shellcheck disable=SC2016 # JavaScript template literals, not shell expansions
node -e '
  const fs = require("node:fs"); const dir = process.argv[1];
  const report = JSON.parse(fs.readFileSync(dir + "/trivy.json", "utf8"));
  const counts = { CRITICAL: 0, HIGH: 0, MEDIUM: 0, LOW: 0, UNKNOWN: 0 }; const notable = [];
  for (const result of report.Results ?? []) for (const v of result.Vulnerabilities ?? []) {
    counts[v.Severity] = (counts[v.Severity] ?? 0) + 1;
    if (v.Severity === "CRITICAL" || v.Severity === "HIGH") notable.push(`| ${v.Severity} | ${v.VulnerabilityID} | ${v.PkgName} ${v.InstalledVersion} | ${v.FixedVersion || "none"} | ${v.PkgPath || result.Target} |`);
  }
  const db = report.Trivy?.Version ?? "";
  fs.writeFileSync(dir + "/summary.md", `### Trivy ${db}: C ${counts.CRITICAL} / H ${counts.HIGH} / M ${counts.MEDIUM} / L ${counts.LOW} / U ${counts.UNKNOWN}\n\n` +
    `libexpat: ${process.argv[2]}. Gate: ${process.argv[3] === "0" ? "passed" : "**FAILED**"} (CRITICAL, less bennett/ci/trivyignore.yaml).\n\n` +
    (notable.length ? `| Severity | ID | Package | Fixed in | Where |\n|---|---|---|---|---|\n${notable.join("\n")}\n` : "") + "\n");
  console.log(fs.readFileSync(dir + "/summary.md", "utf8"));' "$dir" "$libexpat" "$gate"
cat "$dir/critical.txt"
rm -f "$dir/image.tar"
exit "$gate"
