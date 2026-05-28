DEMO_CONFIG ?= config/demo-environment.yaml
DEMO_CONFIG_QUICKSTART ?= config/demo-environment-quickstart.yaml

.PHONY: kind-up kind-recreate kind-down kind-plan


kind-up-quickstart:
	./scripts/create-kind-demo.sh --config $(DEMO_CONFIG_QUICKSTART)

kind-up:
	./scripts/create-kind-demo.sh --config $(DEMO_CONFIG)

kind-recreate:
	./scripts/create-kind-demo.sh --config $(DEMO_CONFIG) --recreate

kind-down:
	./scripts/delete-kind-demo.sh --config $(DEMO_CONFIG)

kind-plan:
	./scripts/create-kind-demo.sh --config $(DEMO_CONFIG) --dry-run
