# Benchmarks

End-to-end benchmark suite for the llm-d flow-control proof-of-concept. Each
scenario isolates a specific flow-control behavior and produces quantitative
results that can be compared in Grafana.

## Prerequisites

| Tool | Purpose |
|---|---|
| `aiperf` | Load generator for OpenAI-compatible APIs |
| `kubectl` | Cluster access (configured for the POC cluster) |
| `curl` / `jq` | API calls and JSON parsing |
| `helm` | EPP configuration swaps between FC/no-FC modes |

The deployment must be running (vLLM pods, EPP, Gateway, Prometheus, Grafana).
See the top-level deployment directories for setup instructions.

**Port-forward Grafana and Prometheus** before running benchmarks so that
annotation and export scripts can reach them:

```bash
kubectl port-forward -n llm-d-monitoring svc/prometheus 9090:9090 &
kubectl port-forward -n llm-d-monitoring svc/grafana 3000:3000 &
```

## Scenarios

| # | Directory | What It Proves |
|---|-----------|----------------|
| 00 | `scenarios/00-baseline-no-fc/` | Performance baseline without flow control |
| 01 | `scenarios/01-baseline-with-fc/` | Performance baseline with flow control enabled |
| 02 | `scenarios/02-priority-tiers/` | Priority-tier differentiation under load |
| 03 | `scenarios/03-intra-tier-fairness/` | Fair capacity sharing among tenants (client's primary interest) |
| 04 | `scenarios/04-batch-vs-interactive/` | Batch workload isolation from interactive traffic |

### Running a Scenario

Each scenario directory has a `run.sh` that handles EPP configuration and
delegates to the orchestrator:

```bash
# Run a single scenario
./benchmarks/scenarios/02-priority-tiers/run.sh

# Or run the full suite in order
for scenario in benchmarks/scenarios/*/run.sh; do
  "${scenario}"
done
```

### Running a Clean Comparison (00 vs 01)

```bash
# 1. Reset environment
./benchmarks/scripts/reset-run.sh

# 2. Run baseline without FC
./benchmarks/scenarios/00-baseline-no-fc/run.sh

# 3. Run baseline with FC
./benchmarks/scenarios/01-baseline-with-fc/run.sh

# 4. Compare in Grafana — the annotations mark each run's time window
```

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `scripts/orchestrator.sh` | Main benchmark runner — reads `scenario.conf`, launches aiperf streams, collects results |
| `scripts/submit-batch-job.sh` | Submits a batch job via the `/v1/batches` API |
| `scripts/annotate-run.sh` | Adds Grafana annotations to mark benchmark start/end times |
| `scripts/reset-run.sh` | Wipes Prometheus TSDB, clears Grafana annotations, archives old results |
| `scripts/export-results.sh` | Exports aiperf JSON output and Prometheus metric snapshots for a run |

## Results Layout

```
benchmarks/results/
├── 00-baseline-no-fc/
│   └── 20260831-141500/
│       ├── stream-1-concurrency-1.json
│       ├── stream-2-concurrency-5.json
│       └── ...
├── 02-priority-tiers/
│   └── 20260831-143000/
│       ├── stream-1-realtime.json
│       ├── stream-2-standard.json
│       └── stream-3-batch-sheddable.json
└── archive/
    └── 20260830-120000/
        └── ...  (moved here by reset-run.sh)
```

## Comparing Results in Grafana

1. **Annotations** — Each `run.sh` creates Grafana annotations at start/end.
   In any Grafana panel, annotations appear as vertical markers so you can
   visually align time-series data with specific benchmark runs.

2. **Key panels to watch**:
   - Request rate per model
   - E2E latency (p50 / p99) per model
   - Time to first token (p50 / p99)
   - KV-cache utilization
   - Flow-control in-flight requests by priority band
   - Flow-control shed requests by priority band

3. **A/B comparison**: Run scenario 00, note the time window, then run
   scenario 01. Zoom Grafana to span both windows — latency and error
   rate differences between FC-off and FC-on will be immediately visible.

## Resetting Between Runs

```bash
./benchmarks/scripts/reset-run.sh
```

This will:
- Archive existing results to `results/archive/<timestamp>/`
- Clear all Grafana benchmark annotations
- Delete the Prometheus pod (emptyDir TSDB is lost, giving a clean slate)
- Wait for Prometheus to come back healthy

## Scenario Configuration Format

Each scenario defines its traffic pattern in a `scenario.conf` file (bash-
sourceable):

```bash
SCENARIO_NAME="02-priority-tiers"
SCENARIO_DURATION=120

STREAM_COUNT=3

STREAM_1_NAME="realtime"
STREAM_1_HEADERS=("-H" "x-llm-d-inference-objective:realtime")
STREAM_1_CONCURRENCY=10
STREAM_1_DATA="prompt_tokens=128,output_tokens=64"
STREAM_1_STREAMING="true"

STREAM_2_NAME="standard"
STREAM_2_HEADERS=("-H" "x-llm-d-inference-objective:standard")
STREAM_2_CONCURRENCY=20
STREAM_2_DATA="prompt_tokens=512,output_tokens=256"
STREAM_2_STREAMING="true"

# ...
```

See any `scenario.conf` file for a complete example.
