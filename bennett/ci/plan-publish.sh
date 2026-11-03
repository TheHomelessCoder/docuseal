#!/usr/bin/env bash
# Decide whether this run publishes. Step outputs: publish (true/false), reason, tag.
# Publishing needs: a request (schedule, or dispatch with publish), the
# bennett-legal branch, the AWS role, and the smoke test having gone through
# the real gateway. A commit that already has a verified image is published
# again only when that image is a week old (fresh OS packages) or on force.
set -euo pipefail
out=${GITHUB_OUTPUT:-/dev/stdout}
today=$(date -u +%Y%m%d)
tag="verified-$today-$SHORT"
decide() {
  {
    echo "publish=$1"
    echo "reason=$2"
    echo "tag=$tag"
  } >> "$out"
  echo "publish=$1: $2"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### Publish: %s\n\n%s\n\n' "$1" "$2" >> "$GITHUB_STEP_SUMMARY"
  exit 0
}

[ "$PUBLISH_REQUESTED" = true ] || decide false 'Not requested (dispatch with publish=false).'
[ "$GITHUB_REF" = refs/heads/bennett-legal ] || decide false "Runs on $GITHUB_REF_NAME publish nothing; only bennett-legal does."
[ -n "${AWS_ROLE_ARN:-}" ] && [ -n "${ECR_REPOSITORY:-}" ] || decide false 'AWS_ROLE_ARN or ECR_REPOSITORY is not set (repository variables).'
[ -n "${GATEWAY_READY:-}" ] || decide false 'The smoke test did not go through the gateway image.'

newest=$(git tag --points-at "$COMMIT" -l 'verified-*' | sort | tail -1)
if [ -n "$newest" ] && [ "${FORCE:-false}" != true ]; then
  stamp=${newest#verified-}
  stamp=${stamp%%-*}
  age=$(( ($(date -u +%s) - $(date -u -d "$stamp" +%s)) / 86400 ))
  [ "$age" -ge 7 ] || decide false "Commit $SHORT is already verified as $newest ($age days old); nothing new."
fi
repository=${ECR_REPOSITORY#*/}
if aws ecr describe-images --repository-name "$repository" --image-ids "imageTag=$tag" > /dev/null 2>&1; then
  decide false "$tag already exists in ECR (tags are immutable); rerun tomorrow or with a new commit."
fi
decide true "Everything passed; publishing $SHORT as $tag."
