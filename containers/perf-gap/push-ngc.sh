#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [nvcr.io/ORG/REPOSITORY]" >&2
    exit 2
fi

repository=${1:-nvcr.io/0980761089281446/kvcr}
repository=${repository%/}
if [[ ! $repository =~ ^nvcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Expected an NGC repository: nvcr.io/ORG/REPOSITORY" >&2
    exit 2
fi

source_image=kv-offload-kvcr:5632b5f64a
target_image=${repository}:priel-5632b5f64a

docker image inspect "$source_image" --format 'Local image: {{.Id}}'
docker tag "$source_image" "$target_image"
docker push "$target_image"
docker buildx imagetools inspect "$target_image"
echo "Published: $target_image"
