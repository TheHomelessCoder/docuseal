#!/usr/bin/env bash
# Push the exact image that was tested to ECR as bl-<commit> (or, for a rebuild
# of an already published commit, bl-<commit>-<yyyymmdd>). The repository's
# tags are immutable. Step output: digest. The verified-* tag is added later,
# by the publish job, after the merge is on bennett-legal.
set -euo pipefail
out=${GITHUB_OUTPUT:-/dev/stdout}
repository=${ECR_REPOSITORY#*/}
tag="bl-$SHORT"
if aws ecr describe-images --repository-name "$repository" --image-ids "imageTag=$tag" > /dev/null 2>&1; then
  tag="bl-$SHORT-$(date -u +%Y%m%d)"
fi
docker tag "$IMAGE" "$ECR_REPOSITORY:$tag"
docker push --quiet "$ECR_REPOSITORY:$tag"
digest=$(aws ecr describe-images --repository-name "$repository" --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text)
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::No digest for $tag"; exit 1; }
# The registry must hold the bytes that were tested.
docker image inspect --format '{{join .RepoDigests "\n"}}' "$ECR_REPOSITORY:$tag" | grep -qx "$ECR_REPOSITORY@$digest"
{
  echo "digest=$digest"
  echo "pushed_tag=$tag"
} >> "$out"
echo "Pushed $tag ($digest)"
