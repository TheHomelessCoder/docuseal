#!/usr/bin/env bash
# Merge upstream DocuSeal into the checked-out branch, in this work copy only.
# Nothing is pushed here. Step outputs (GITHUB_OUTPUT): upstream, upstream_short,
# base_tag, before, commit, short, changed, and on failure conflict, reason, files.
set -euo pipefail
url=${UPSTREAM_URL:-https://github.com/docusealco/docuseal.git}
branch=${UPSTREAM_BRANCH:-master}
out=${GITHUB_OUTPUT:-/dev/stdout}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git fetch --quiet --no-tags "$url" "+refs/heads/$branch:refs/remotes/upstream/$branch" '+refs/tags/*:refs/tags/*'
upstream=$(git rev-parse "refs/remotes/upstream/$branch")
before=$(git rev-parse HEAD)
base_tag=$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' "$upstream" 2> /dev/null || echo unknown)
# Upstream controls tag names; keep only a plain version for later steps.
[[ $base_tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || base_tag=unknown
{
  echo "upstream=$upstream"
  echo "upstream_short=${upstream:0:7}"
  echo "base_tag=$base_tag"
  echo "before=$before"
} >> "$out"

stop() { # stop REASON FILES...
  local reason=$1
  shift
  {
    echo 'conflict=true'
    echo "reason=$reason"
    echo "files=$*"
  } >> "$out"
  echo "::error::Upstream merge needs a person ($reason): $*"
  exit 1
}

if git merge-base --is-ancestor "$upstream" HEAD; then
  changed=false
  echo "bennett-legal already contains upstream $branch ${upstream:0:7} ($base_tag)"
else
  if ! git merge --no-ff --no-edit -m "Merge upstream DocuSeal $branch ${upstream:0:7} ($base_tag)" "$upstream" > /dev/null 2>&1; then
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git merge --abort || true
    # shellcheck disable=SC2086 # one argument per file name
    stop conflict $files
  fi
  # GITHUB_TOKEN may not push changes to workflow files; a person must merge.
  workflows=$(git diff --name-only "$before" HEAD -- .github/workflows | tr '\n' ' ')
  # shellcheck disable=SC2086
  [ -z "$workflows" ] || stop workflows $workflows
  changed=true
  echo "Merged upstream $branch ${upstream:0:7} ($base_tag): $(git diff --name-only "$before" HEAD | wc -l | tr -d ' ') files changed"
fi
commit=$(git rev-parse HEAD)
{
  echo "changed=$changed"
  echo "commit=$commit"
  echo "short=$(git rev-parse --short=7 HEAD)"
} >> "$out"

# For the run summary: upstream changes in code the Bennett layer, the gateway
# allowlist or JUD depend on. Informational; the tests and smoke test decide.
if [ "$changed" = true ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  watched=$(git diff --name-only "$before" HEAD -- config/routes.rb config/storage.yml config/puma.rb Dockerfile \
    'app/controllers/submit_form*' 'app/controllers/api/*' 'app/controllers/start_form*' lib/submitters lib/submissions \
    lib/webhook_urls.rb lib/webhook_urls lib/send_webhook_request.rb app/javascript/submission_form app/views/submit_form \
    app/views/start_form app/views/layouts app/mailers app/views/submitter_mailer LICENSE LICENSE_ADDITIONAL_TERMS)
  {
    echo "### Upstream merge: ${upstream:0:7} ($base_tag)"
    echo
    echo "$(git rev-list --count "$before..$upstream") upstream commits, $(git diff --name-only "$before" HEAD | wc -l | tr -d ' ') files."
    if [ -n "$watched" ]; then
      echo
      echo 'Changed files the Bennett layer, the gateway allowlist or JUD depend on:'
      echo
      while read -r file; do echo "- \`$file\`"; done <<< "$watched"
    fi
    echo
  } >> "$GITHUB_STEP_SUMMARY"
fi
