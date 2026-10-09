# Local KV offload image build

See [CHANGES.md](CHANGES.md) for the source revisions, image digest, shipped
vLLM changes, and validation status.

Run `./build.sh` from this directory on a shell with access to the Docker
daemon. By default it expects the pinned vLLM checkout at
`../vllm-main` relative to the KVCR checkout; set `VLLM_DIR` to use another
location. It produces
`kv-offload-kvcr:5632b5f64a` in two steps:

1. Build vLLM from the local `perf-gap/11-numa-diagnostics` checkout with
   vLLM's CUDA Dockerfile and native extensions from its upstream merge base.
2. Layer the local KVCR checkout and the Dynamo revision pinned by KVCR's
   quick start on that image. The final Dockerfile checks Python imports and
   the expected package versions during the build.

The stock KVCR quick start fetches an older vLLM commit, which would omit the
local performance changes. This recipe replaces that step with a local vLLM
build. It leaves vLLM's optional `kv_connectors` extras off so KVCR installs
its pinned NIXL 1.3.2. This combination needs a runtime KVCR test on the
target GPU host; the build-time import check cannot prove transfer behavior.

If the upstream precompiled vLLM wheel is unavailable for the merge-base
commit, retry with `VLLM_USE_PRECOMPILED=0 ./build.sh` to compile from source.
That path needs more time and disk space.

The script checks the exact vLLM revision, confirms that the KVCR package
files still match the pinned revision, and requires clean working trees before
building. It does not push images or clear any runtime cache.

To publish the built image to `nvcr.io/0980761089281446/kvcr:priel-5632b5f64a`, run
`./push-ngc.sh` from a Docker-enabled shell. The script tags and pushes the
local image and then reads the remote manifest digest. A different NGC
repository may be supplied as its sole argument.
