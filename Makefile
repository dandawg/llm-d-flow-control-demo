.PHONY: help cluster-up cluster-down scale-up scale-down deploy deploy-no-fc teardown verify \
       benchmark-00 benchmark-01 benchmark-02 benchmark-03 benchmark-04 \
       reset-benchmarks swap-fc-on swap-fc-off observability-port-forward

SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-28s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------

cluster-up: ## Create the EKS cluster (takes ~15-20 min)
	bash cluster/create-cluster.sh

cluster-down: ## Delete the EKS cluster permanently
	bash cluster/delete-cluster.sh

cluster-status: ## Show cluster state, node counts, and estimated cost
	bash cluster/cluster-status.sh

scale-up: ## Restore full capacity (2 GPU + 2 CPU nodes)
	bash cluster/scale-up.sh

scale-down: ## Scale to minimum (0 GPU, 1 CPU) — saves ~$$2.10/hr
	bash cluster/scale-down.sh

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------

deploy: ## Deploy the full llm-d stack with flow control
	bash deployment/scripts/deploy-all.sh

deploy-no-fc: ## Deploy the stack WITHOUT flow control (baseline)
	FC_MODE=off bash deployment/scripts/deploy-all.sh

teardown: ## Tear down all deployed resources
	bash deployment/scripts/teardown.sh

verify: ## Verify all components are healthy
	bash deployment/scripts/verify-deployment.sh

swap-fc-on: ## Enable flow control on a running deployment
	bash deployment/scripts/swap-flow-control.sh on

swap-fc-off: ## Disable flow control on a running deployment
	bash deployment/scripts/swap-flow-control.sh off

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

observability-port-forward: ## Port-forward Prometheus (9090) and Grafana (3000)
	@echo "Starting port-forwards (Ctrl+C to stop)..."
	@kubectl port-forward -n llm-d-monitoring svc/prometheus 9090:9090 &
	@kubectl port-forward -n llm-d-monitoring svc/grafana 3000:3000 &
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana:    http://localhost:3000 (admin/admin)"
	@wait

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------

benchmark-00: ## Run Scenario 0: Baseline without flow control
	bash benchmarks/scenarios/00-baseline-no-fc/run.sh

benchmark-01: ## Run Scenario 1: Baseline with flow control
	bash benchmarks/scenarios/01-baseline-with-fc/run.sh

benchmark-02: ## Run Scenario 2: Priority tiers under saturation
	bash benchmarks/scenarios/02-priority-tiers/run.sh

benchmark-03: ## Run Scenario 3: Intra-tier fairness
	bash benchmarks/scenarios/03-intra-tier-fairness/run.sh

benchmark-04: ## Run Scenario 4: Batch vs interactive (/v1/batches)
	bash benchmarks/scenarios/04-batch-vs-interactive/run.sh

reset-benchmarks: ## Wipe metrics and results for a fresh start
	bash benchmarks/scripts/reset-run.sh
