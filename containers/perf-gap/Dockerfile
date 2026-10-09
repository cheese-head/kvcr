# syntax=docker/dockerfile:1.7
# Local-source variant of KVCR's Dockerfile.quick-start.
ARG VLLM_IMAGE=kv-offload-vllm:5632b5f64a

FROM rust:1.93-bookworm AS build-base
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake git libclang-dev libhwloc-dev libprotobuf-dev libudev-dev pkg-config \
    protobuf-compiler python3-dev python3-pip python3-venv \
 && rm -rf /var/lib/apt/lists/*

FROM build-base AS dynamo-builder
ARG DYNAMO_REF=58f1e01f76cbcf46a08963ffcab85c774da32a43
RUN git clone --filter=blob:none https://github.com/ai-dynamo/dynamo.git /src/dynamo \
 && git -C /src/dynamo fetch --depth 1 origin "${DYNAMO_REF}" \
 && git -C /src/dynamo checkout --detach "${DYNAMO_REF}"
RUN python3 -m venv /venv \
 && /venv/bin/pip install --no-cache-dir "maturin[patchelf]"
RUN cd /src/dynamo/lib/bindings/python \
 && /venv/bin/maturin build --release --features select-service,kv-indexer \
      --out /wheels
RUN cd /src/dynamo \
 && /venv/bin/pip wheel --no-deps . --wheel-dir /wheels

FROM ${VLLM_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libatomic1 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=dynamo-builder /wheels /tmp/dynamo-wheels
RUN python3 -m pip install --no-cache-dir --no-deps \
      /tmp/dynamo-wheels/ai_dynamo_runtime-*.whl \
 && python3 -m pip install --no-cache-dir --no-deps \
      /tmp/dynamo-wheels/ai_dynamo-*.whl \
 && rm -rf /tmp/dynamo-wheels

COPY pyproject.toml README.md LICENSE /opt/kvcr-src/
COPY src /opt/kvcr-src/src
RUN python3 -m pip install --no-cache-dir /opt/kvcr-src

# Catch a dependency or Python API mismatch before naming the image usable.
RUN python3 - <<'PY'
from importlib import metadata
import dynamo.vllm
import kvcr
import nixl
import vllm
from vllm.v1.kv_offload.tiering.kvcr.manager import KVCRSecondaryTierManager
from vllm.v1.kv_offload.tiering.spec import TieringOffloadingSpec
from vllm.v1.kv_offload.cpu.common import CPUOffloadingMetrics

assert metadata.version("nixl") == "1.3.2"
assert KVCRSecondaryTierManager.supports_residency_claims
assert CPUOffloadingMetrics.CPU_INVALIDATED_CHUNKS
assert TieringOffloadingSpec
for name in ("ai-dynamo", "vllm", "kvcr", "nixl"):
    print(f"{name}=={metadata.version(name)}")
print("vllm source:", vllm.__file__)
print("kvcr source:", kvcr.__file__)
print("dynamo source:", dynamo.vllm.__file__)
PY

ENV DYN_REQUEST_PLANE=tcp \
    DYN_EVENT_PLANE=zmq \
    DYN_DISCOVERY_BACKEND=file \
    DYN_FILE_KV=/tmp/dynamo-kvcr-perf-gap \
    PYTHONHASHSEED=0 \
    VLLM_KV_EVENTS_USE_INT_BLOCK_HASHES=1
ENTRYPOINT []
