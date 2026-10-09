#!/usr/bin/env bash
set -euo pipefail

recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
kvcr_dir=$(cd -- "$recipe_dir/../.." && pwd)
vllm_dir=${VLLM_DIR:-$(dirname "$kvcr_dir")/vllm-main}
vllm_commit=5632b5f64a3007d493fb513f4cc4066bc42598de
kvcr_package_commit=317e62f301300c101bf9c911e020fb89b35f1583
vllm_base=2840ca7a332525fe73bbc55ef508722372875823
vllm_image=kv-offload-vllm:5632b5f64a
image=kv-offload-kvcr:5632b5f64a

test "$(git -C "$vllm_dir" rev-parse HEAD)" = "$vllm_commit"
git -C "$kvcr_dir" merge-base --is-ancestor "$kvcr_package_commit" HEAD
git -C "$kvcr_dir" diff --quiet "$kvcr_package_commit" HEAD -- src pyproject.toml uv.lock
test -z "$(git -C "$vllm_dir" status --porcelain)"
test -z "$(git -C "$kvcr_dir" status --porcelain)"
docker version --format '{{.Server.Version}}' >/dev/null

DOCKER_BUILDKIT=1 docker build \
    --progress=plain \
    --target vllm-openai \
    --file "$vllm_dir/docker/Dockerfile" \
    --tag "$vllm_image" \
    --build-arg VLLM_USE_PRECOMPILED="${VLLM_USE_PRECOMPILED:-1}" \
    --build-arg VLLM_MERGE_BASE_COMMIT="$vllm_base" \
    --build-arg VLLM_BUILD_COMMIT="$vllm_commit" \
    --build-arg max_jobs=6 \
    --build-arg nvcc_threads=2 \
    "$vllm_dir"

DOCKER_BUILDKIT=1 docker build \
    --progress=plain \
    --file "$recipe_dir/Dockerfile" \
    --tag "$image" \
    --build-arg VLLM_IMAGE="$vllm_image" \
    "$kvcr_dir"

docker image inspect "$image" --format '{{.Id}} {{.Size}}'
