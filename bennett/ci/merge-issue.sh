#!/usr/bin/env bash
# One GitHub issue tracks a stopped upstream merge.
#   merge-issue.sh open    open it, or update it if it is already open
#   merge-issue.sh close   close it once a nightly build passes again
# Needs GH_TOKEN (issues: write). open also reads REASON, FILES, UPSTREAM_SHORT, BASE_TAG.
set -euo pipefail
label=upstream-merge
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
branch=${GITHUB_REF_NAME:-bennett-legal}
open_issue() { gh issue list --repo "$GITHUB_REPOSITORY" --label "$label" --state open --json number --jq '.[0].number // empty'; }

case "${1:-}" in
  open)
    gh label create "$label" --repo "$GITHUB_REPOSITORY" --color B60205 \
      --description 'The nightly upstream merge stopped and needs a person' > /dev/null 2>&1 || true
    if [ "$REASON" = workflows ]; then
      why='Upstream changed workflow files. The nightly token may not push those, so a person has to merge this one.'
    else
      why='The merge has conflicts.'
    fi
    # shellcheck disable=SC2016,SC2153 # literal backticks; FILES comes from the workflow
    files=$(for file in $FILES; do printf -- '- `%s`\n' "$file"; done)
    body=$(cat << EOF
The nightly build could not merge upstream DocuSeal \`${UPSTREAM_BRANCH:-master}\` (\`$UPSTREAM_SHORT\`, $BASE_TAG) into \`$branch\` by itself. Nothing was built or published.

$why

$files

Latest run: $run_url

To finish by hand, keeping the Bennett changes (\`bennett/NOTICE.md\` lists them):

\`\`\`sh
git fetch https://github.com/docusealco/docuseal.git ${UPSTREAM_BRANCH:-master}
git checkout $branch && git merge FETCH_HEAD   # resolve the files above
ruby bennett/test/run.rb
git push origin $branch
gh workflow run bennett-nightly.yml --ref $branch
\`\`\`

This issue closes itself after the next passing nightly build.
EOF
    )
    number=$(open_issue)
    if [ -n "$number" ]; then
      gh issue edit "$number" --repo "$GITHUB_REPOSITORY" --body "$body" > /dev/null
      gh issue comment "$number" --repo "$GITHUB_REPOSITORY" --body "Still stopped: $run_url" > /dev/null
      echo "Updated issue #$number"
    else
      gh issue create --repo "$GITHUB_REPOSITORY" --title 'Nightly upstream merge needs a person' --label "$label" --body "$body"
    fi
    ;;
  close)
    number=$(open_issue)
    if [ -n "$number" ]; then
      gh issue close "$number" --repo "$GITHUB_REPOSITORY" --comment "Merged and verified in $run_url" > /dev/null
      echo "Closed issue #$number"
    fi
    ;;
  *)
    echo 'usage: merge-issue.sh open|close' >&2
    exit 2
    ;;
esac
