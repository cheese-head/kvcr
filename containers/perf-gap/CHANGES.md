# KV offload performance image: changes and hypotheses

## Artifact and scope

| Component | Revision or artifact |
| --- | --- |
| NGC image | `nvcr.io/0980761089281446/kvcr:priel-5632b5f64a` |
| OCI index digest | `sha256:d9b13df95d8f15291f6e33dc2a530e74e79745d6e79351b23cd36b06e96a847f` |
| vLLM | Local `perf-gap/11-numa-diagnostics` at `5632b5f64a3007d493fb513f4cc4066bc42598de` |
| vLLM base | `2840ca7a332525fe73bbc55ef508722372875823` |
| KVCR package | Source files from `317e62f301300c101bf9c911e020fb89b35f1583`; image recipe committed separately |
| Dynamo | KVCR quick-start pin `58f1e01f76cbcf46a08963ffcab85c774da32a43` |
| NIXL | KVCR dependency `1.3.2` |

The image builds the **local vLLM source**, then installs the local KVCR
package and the pinned Dynamo wheels. The stock KVCR quick-start fetches an
older vLLM revision and would omit these changes. KVCR's package source is
unchanged; the KVCR adapter changes below are in vLLM. The vLLM source branch
also contains tests and two plan-only commits (`0ee2c124c1`, `d020aa9c2c`);
the runtime image installs the resulting vLLM package, not those test files.

## Why this image exists

The operator reported three observations that have not yet been reproduced or
explained by this image:

1. Simple CPU offload and native tiering's CPU-primary mode differ in
   performance **without KVCR**, including when tiering has
   `secondary_tiers: []`. The baseline discrepancy is therefore in setup,
   allocation/admission, the tiering wrapper, or GPU↔CPU movement. KVCR
   deposit policy cannot be its cause.
2. Native tiering generated more offload traffic than simple CPU in an
   agentic run. The question is whether the extra bytes are GPU-primary
   stores, CPU-secondary cascades, promotions after CPU misses, or repeated
   work after eviction.
3. TTFT had large spikes around 60 minutes. A long-running, never-cleared
   cache may expose capacity pressure, evicted prefixes, transfer pins,
   secondary backpressure, or NUMA placement effects that a short run misses.

The new metrics establish comparable observations first. The optional policies
then change one mechanism at a time. They are experiments, not measured fixes.
Do **not** clear the live cache between measurements; retain the workload's
natural cache history and record configuration and image digest with each run.

## First priority: explain the CPU-only gap

The first comparison is **simple CPU offload versus native tiering with an
empty secondary list**. Keep the same model, request stream, CPU byte budget,
chunk size, layout, GPU topology, and normal cache history. In particular,
check `store_threshold`: simple CPU supports an admission threshold, while
tiering rejects values of 2 or more. A threshold mismatch would change the
amount of KV stored before any transport difference matters.

These counters have the same GPU-facing meaning on both paths:

| Compare across simple CPU and tiering CPU-only | What it separates |
| --- | --- |
| `vllm:kv_offload_store_chunks{stage=...}` | Keys offered, selected, filtered/already resident, rejected, and completed. Different counts mean the paths are doing different useful work. |
| `vllm:kv_offload_store_bytes`, `vllm:kv_offload_load_bytes` | Actual GPU↔CPU movement. Equal bytes with different latency suggests transfer speed or scheduler overhead rather than volume. |
| `vllm:kv_offload_store_time`, `vllm:kv_offload_load_time` | Worker-reported transfer time. Compare with bytes, not TTFT alone. |
| `vllm:kv_offload_manager_hook_duration_seconds` | Time spent in common scheduler calls into each manager. Higher tiering time with equal bytes points toward wrapper/bookkeeping work. |
| `vllm:kv_offload_cpu_cache_slots`, CPU allocation failures, evictions, and misses after eviction | Whether the CPU cache reaches pressure, pins, or different retention outcomes. |

The source has a concrete placement difference worth checking first: simple
CPU's workers normally first-touch their slices of the shared region, while
tiering's scheduler populates its primary region before secondary setup. If
selected chunks and GPU bytes match but transfer time differs, use the opt-in
NUMA startup log to compare actual page placement. If placement and transfer
time match but tiering hook time is higher, investigate tiering's per-request
state and completion polling. If selected chunks or evictions differ, inspect
admission and cache state before attributing the gap to memory bandwidth.

With no secondary, tiering's CPU↔secondary bytes, KVCR entry outcomes, and
write-policy claims should be absent or zero. The tracked write-through,
write-back, and invalidation branches are **not explanations for this
CPU-only gap**. Evaluate them only after the baseline difference is
understood, then add KVCR to explain its additional traffic.

## Measurement changes

### 1. Common simple-CPU/tiering accounting — `2f49b7ad9b`

The scheduler now counts each GPU-to-primary store offer as `offered`,
`selected`, `not_selected`, or `rejected_offer` under
`vllm:kv_offload_store_chunks`. It also times common manager calls in
`vllm:kv_offload_manager_hook_duration_seconds`. Existing transfer metrics
report GPU-to-offload `vllm:kv_offload_store_bytes` and
`vllm:kv_offload_load_bytes` for both methods.

**Why:** A larger tiering byte count could simply mean more chunks were
selected for storage. Equal selected chunks and equal GPU transfer bytes, with
higher hook time, point instead to scheduler/manager overhead. Equal bytes but
slower transfer time point toward memory placement or transfer execution.

**Limit:** `not_selected` combines already-resident and filtered keys;
interpret it with CPU cache state. These common byte counters describe the
GPU-facing transfer; they do not include CPU-to-KVCR cascades.

### 2. CPU residency and eviction evidence — `1c72b34682`

The CPU manager now reports slot states, allocation failures, eviction counts,
and misses after a **recorded** eviction. Slot states distinguish free,
evictable, write-pending, and read-pinned capacity. The recent-eviction history
is bounded to 64,000 keys.

**Why:** An apparently empty or slow cache could be full of write-pending or
read-pinned slots, or repeatedly evict useful prefixes. Allocation failures
and later misses should be aligned with TTFT spikes and load behavior.

**What it can prove:** A miss counted by
`vllm:kv_offload_cpu_misses_after_eviction` has direct, bounded evidence of a
prior CPU eviction. A zero count does **not** prove no evicted key was missed:
older history can age out, and a key may be absent for other reasons.

### 3. Tiering transfer and queue visibility — `b22f58082f`

Tiering now reports secondary read/write bytes and time, job duration and key
counts, active cascade/promotion jobs, cascade pin lifetime, promotion
outcomes, backpressure drops, lookup delay, and hook duration.

**Why:** The reported extra traffic must be assigned to a boundary. If common
GPU-to-primary store bytes match simple CPU but tiering write bytes rise, the
extra traffic is in primary-to-secondary cascades. If promotion jobs and
secondary read bytes rise late in the run, previously offloaded data is being
read back through the CPU primary. Long pins and allocation failures can
explain pressure even when total CPU capacity is unchanged.

**Limit:** Tiering read/write bytes are **CPU↔secondary** bytes, while the
common load/store bytes are **GPU↔primary** bytes. Add them only when estimating
total movement; do not treat them as equivalent counters.

### 4. KVCR per-entry outcomes — `d6a80bf0f0`

The vLLM KVCR adapter counts completion entries by operation and status in
`vllm:kvcr_adapter_entry_results` when the secondary has
`enable_telemetry: true`. KVCR's own duration, transfer-byte, and state
metrics remain available through the adapter.

**Why:** A submitted cascade is not the same as a retained lower-tier copy.
Per-entry results distinguish successful deposits or deliveries from dropped
or failed entries, including mixed batches. This helps explain whether excess
traffic buys useful secondary residency.

## Optional behavior experiments

All of these behaviors are **off by default**. The first comparison should use
existing `best_effort` tiering and ordinary LRU, with the new measurement
counters enabled where applicable.

### 5. NUMA placement — `2c0022765e`; startup diagnostics — `5632b5f64a`

Tiering can set `cpu_numa_nodes: "auto"` or one explicit node per worker slot.
For the supported non-canonical, non-replicated layout, the scheduler
first-touches each worker slice under a temporary memory binding before the
secondary registers the shared buffer. The prior policy is restored afterward.
With `cpu_numa_diagnostics: true`, both simple CPU and tiering log process,
slot, affinity, allowed memory nodes, and the mmap's per-node page counts at
startup.

**Hypothesis:** Simple CPU and tiering may first-touch the same total bytes
from different processes, producing different NUMA placement. A remote CPU
allocation can increase GPU-host transfer time without changing bytes or cache
hit rates. If placement differs and the opt-in binding aligns it, matched
GPU transfer time and TTFT should converge. If placement already matches,
look at wrapper/hook cost and admission decisions instead.

**Limits:** The startup log is a snapshot, not proof of later placement.
Physical page sampling, NIXL registration behavior, and GPU-runtime checks
remain to be done on the target host. Leave binding off until those checks
support it.

### 6. Lineage-aware CPU eviction — `78e98973cb`

The optional `eviction_policy: "leaf_first_lru"` carries parent offload-key
metadata for full-attention groups. It admits children only with a resident or
same-batch parent, tracks resident children, and chooses the oldest eligible
leaf before a parent. Multi-slot eviction selection is atomic: it fails
without removing a partial set if too few eligible leaves exist.

**Hypothesis:** Ordinary LRU can leave a descendant in CPU after its ancestor
was evicted. For prefix lookup, that descendant may be unusable. Preserving
ancestors while evicting tails first should reduce misses and recomputation
when this pattern is material. A benefit should show as fewer misses after
CPU eviction, longer useful prefix hits, and lower TTFT at comparable CPU
capacity. If scan cost or admission failures rise without better hits, this
policy is not useful for the workload.

**Limits:** Scope is full-attention lineage only. The policy does not alter
the content-addressed key and is not enabled for sliding-window or recurrent
groups by default. Aggregate counters alone cannot prove a specific
ancestor-before-descendant event; inspect a bounded lineage trace if the
hypothesis matters.

### 7. Tracked asynchronous write-through — `6251708a74`

`write_policy: "tracked_write_through"` keeps the eager secondary deposit
but records per-key copying, success, and failure. The KVCR adapter returns
per-key completion rather than treating a mixed batch as wholly successful.
The primary slot remains pinned while its async cascade reads it.

**Hypothesis:** Best-effort cascading may send bytes that are dropped or fail
without a clear link to later cache hits. This mode reveals whether submitted
writes become confirmed lower-tier copies, and whether duplicate or failed
cascades contribute to traffic and tail latency.

**Limit:** This mode is asynchronous and opportunistic. A successful deposit
is not a permanent residency guarantee; KVCR may evict it later. It does not
wait for secondary acknowledgement before GPU-facing store completion.

### 8. Claimed write-back — `badae44856`

`write_policy: "write_back"` delays KVCR deposits until CPU-primary capacity
pressure triggers a flush. Before a CPU copy can be evicted, a KVCR local-G2
`no_evict` deposit must return a residency claim for that key. Keys lacking a
claim are protected from CPU eviction. Claimed keys can be reused/evicted from
CPU; claims are released on cache reset or shutdown.

**Hypothesis:** If eager write-through is the main source of extra traffic,
write-back should lower secondary deposit bytes per useful GPU store, while
moving some work to eviction pressure. The tradeoff is visible in claim count,
CPU allocation failures, cascade pin time, job duration, and TTFT tails. A
large late spike could indicate flush pressure rather than transfer bandwidth.

**Limits:** This first implementation supports KVCR local G2, not Guard. Hard
claims consume lower-tier capacity, and a full pool may block admission.
Reset and restart semantics must be verified before relying on it operationally.
No benchmark result yet shows a net performance gain.

### 9. Write-through with CPU invalidation — `05890f140e`

`write_policy: "write_through_invalidate"` deposits eagerly. After a
successful per-key completion, it invalidates the matching CPU slot only when
its readers have released it. A slot-generation check prevents a late
completion from invalidating a newer copy at the same slot. Failed deposits
leave the CPU copy in place. `vllm:kv_offload_cpu_invalidated_chunks` counts
completed invalidations, including delayed ones.

**Hypothesis:** Keeping both CPU and KVCR copies may waste scarce primary
capacity. Invalidation should free CPU slots and reduce allocation failures,
but may increase later KVCR promotions and GPU load traffic. It is a capacity
experiment; a lower CPU occupancy alone is not a performance win.

**Limits:** This mode requires KVCR local G2 and ordinary LRU. It does not
promise that the lower copy remains resident forever. Compare freed slots
with subsequent promotion bytes and TTFT before using it for production.

## Reading one run

| Observation | First metrics or evidence to check | Likely next question |
| --- | --- | --- |
| Tiering slower with `secondary_tiers: []` | Common selected store chunks, GPU store/load bytes and time, manager hook duration, CPU slot states, startup NUMA map | Are bytes equal but page locality or hook time different? |
| More offload traffic with KVCR | Common GPU bytes versus tiering secondary write/read bytes; KVCR entry results and transfer bytes | Is the increase eager cascades, retries/failures, or later promotions? |
| TTFT spike after a long run | CPU free/pinned/write-pending slots, allocation failures, misses after eviction, active jobs, pin duration, backpressure and KVCR outcomes | Did the cache lose a useful prefix, saturate capacity, or queue transfers? |
| Policy appears to improve hit rate | CPU eviction/miss counts **and** GPU/secondary bytes, allocation failures, TTFT | Did it trade transfer work or stalls for those hits? |

Keep CPU capacity, chunk size, layout, request stream, and image digest aligned
when comparing simple CPU to tiering without a secondary. The common metrics
are equivalent across those paths; tiering-only and KVCR metrics explain work
that exists only after adding a secondary. This document describes the
instrumentation and expected signals, not results from a benchmark.

## Validation and remaining risks

Static compilation, Ruff, formatting, and diff checks passed for the vLLM
branch. The image build completed and imported Dynamo, vLLM, KVCR, and NIXL.
The NGC digest above was verified after the push. No GPU transfer test or
benchmark result has been recorded here. The build-time `vllm._C` warning
occurred without a CUDA runtime; a GPU run must verify
`vllm._C_stable_libtorch` and an actual KVCR transfer.

KVCR pins NIXL 1.3.2, while this vLLM checkout's optional connector
requirements name NIXL 1.4.1. The image follows KVCR's pin; runtime API
compatibility remains to be verified. No live cache was cleared. The
benchmark operator owns workload execution and interpretation.

For the deeper design, validation cases, and branch sequence, see the
[implementation plan](../workspace/vllm-main/docs/design/kv_offload_perf_gap_implementation.md).
