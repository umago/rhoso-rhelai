# Limitation based on the code here: We can have multiple cards, but they must all be of the same kind

# The qcow2 download URL from https://access.redhat.com/downloads/content/932
AI_IMAGE_URL ?=
# Number of GPUs to assign to the RHEL AI instance, by default assign them all to a single instance
AI_NUM_GPUS ?= all
AI_VM_NAME ?= rhel-ai
AI_CPUS ?= 20
AI_RAM ?= 40
AI_DISK ?= 600

DEPLOY_CINDER ?= false
PULL_SECRET ?= ~/pull-secret

# We ping the CRC version because we don't want to uPULL_SECRET=~/pull-secretse a version too modern
CRC_VERSION ?= 2.43.0

# Reasonable defaults for CRC CPU, DISK, and RAM
CRC_CPUS ?= 12
CRC_RAM ?= 24
CRC_DISK ?= 100

EDPM_CPUS ?= 28
EDPM_RAM ?= 100
# We need a lot of space because models are not quantized
EDPM_DISK ?= 640

# NVIDIA PCI Vendor ID
GPU_VENDOR_ID ?= 10de
GPU_PRODUCT_ID ?=

TIMEOUT_OPERATORS ?= 600s
TIMEOUT_CTRL ?= 30m
TIMEOUT_EDPM ?= 40m

ifeq ($(DEPLOY_CINDER), true)
KUSTOMIZE_TEMPLATE := templates/kustomization-cinder.yaml
else
KUSTOMIZE_TEMPLATE := templates/kustomization-no-cinder.yaml
endif
NOVA_CFG_TEMPLATE := templates/nova-compute.conf

INSTALL_YAMLS_DIR ?= out/install_yamls

# When cleaning up the EDPM we would normally cleanup nicely, but if OCP is
# down we would do it more forcefully
OCP_DOWN ?= false

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ PREPARATIONS
.PHONY: download_tools
download_tools: ## Installs basic tools, clones or updates the install_yaml repo, and then runs install_yaml's devsetup download_tools
	@sudo dnf -y install git ansible-core libvirt-daemon-common
ifeq (,$(wildcard $(INSTALL_YAMLS_DIR)))
	@git clone https://github.com/openstack-k8s-operators/install_yamls.git $(INSTALL_YAMLS_DIR)
else
	@cd $(INSTALL_YAMLS_DIR) && git remote update && git checkout origin/main
endif
	@make -C $(INSTALL_YAMLS_DIR)/devsetup download_tools

.PHONY: validate_host
validate_host: ## Check host has appropriate tools are install, the presence of NVIDIA GPU, availability of GPU, IOMMU, etc.
	@which git > /dev/null
	@which virt-host-validate > /dev/null
	@if [[ ! "$$(sudo virt-host-validate | grep IOMMU | cut -f3 -d:)" =~ PASS.*PASS ]]; then echo '✗ IOMMU corretly configured'; false; else echo '✔ IOMMU correctly configured'; fi
	@if ! lspci -n |grep ": $(GPU_VENDOR_ID):" > /dev/null; then echo '✗: NVIDIA GPU found'; false; else echo '✔ NVIDIA GPU found'; fi
	@lspci -n | grep ': $(GPU_VENDOR_ID):' | cut -f1 -d' ' | while read line; do if lspci -k -s$$line | grep vfio-pci > /dev/null; then echo "✔ GPU held by vfio-pci: $$line"; else echo "✗ GPU held by vfio-pci: $$line" && false; fi done

##@ DEPLOY
.PHONY: prepare_controlplane_config
prepare_controlplane_config: ## Prepare the control plane configuration
ifeq ($(GPU_PRODUCT_ID),)
	$(eval GPU_PRODUCT_ID := $(shell lspci -n  |grep $(GPU_VENDOR_ID) | cut -f3 -d' '| cut -f2 -d: | head -n1))
endif
	$(info Using GPU product ID $(GPU_PRODUCT_ID) (can be changed using GPU_PRODUCT_ID env var))
	$(info Generating the OpenStackControlPlane manifest)
	@mkdir -p out/ctlplane
	@sed 's/$${VENDOR_ID}/$(GPU_VENDOR_ID)/g;s/$${PRODUCT_ID}/$(GPU_PRODUCT_ID)/g' $(KUSTOMIZE_TEMPLATE) > out/ctlplane/kustomization.yaml
	@eval $$(crc oc-env) && \
	oc kustomize ./out/ctlplane > ./out/openstack-deployment.yaml

.PHONY: create_storage
create_storage:
	@NNCP_TIMEOUT=$(TIMEOUT_OPERATORS) TIMEOUT=$(TIMEOUT_OPERATORS) make -C $(INSTALL_YAMLS_DIR) crc_storage openstack_wait

# Create storage sometime fails, so we repeat it once on failure
.PHONY: deploy_controlplane
deploy_controlplane: ## Deploy OCP cluster using CRC, deploy OSP operators, and deploy the OpenStack Control Plane
	@echo Deploying OCP using CRC && \
	CRC_VERSION=$(CRC_VERSION) PULL_SECRET=$$(realpath $(PULL_SECRET)) CPUS=$(CRC_CPUS) MEMORY=$$((1024*$(CRC_RAM))) DISK=$(CRC_DISK) make -C $(INSTALL_YAMLS_DIR)/devsetup crc crc_attach_default_interface && \
	echo Deploying RHOSO operators && \
	eval $$(crc oc-env) && \
	( $(MAKE) create_storage || $(MAKE) create_storage ) && \
	oc label node --all openstack.org/cinder-lvm= && \
	$(MAKE) prepare_controlplane_config && \
	sleep 60 && \
	echo Deploying RHOSO control plane && \
	OPENSTACK_CR=$$(realpath ./out/openstack-deployment.yaml) make -C $(INSTALL_YAMLS_DIR) openstack_deploy && \
	echo Waiting for control plane to be ready && \
	oc wait openstackcontrolplane openstack --for condition=Ready --timeout=$(TIMEOUT_CTRL) && \
	echo "Run eval $$(crc oc-env) to be able to access the OCP cluster using the oc command"

.PHONY: deploy_edpm
deploy_edpm: ## Deploy an eDPM node with PCI passthrough
	$(eval $(call vars))
ifeq ($(GPU_PRODUCT_ID),)
	$(eval GPU_PRODUCT_ID := $(shell lspci -n  |grep $(GPU_VENDOR_ID) | cut -f3 -d' '| cut -f2 -d: | head -n1))
endif
	$(info Generating nova compute config)
	@sed 's/$${VENDOR_ID}/$(GPU_VENDOR_ID)/g;s/$${PRODUCT_ID}/$(GPU_PRODUCT_ID)/g' $(NOVA_CFG_TEMPLATE) > ./out/nova-compute.conf

	$(info Generating eDPM SSH key)
	@eval $$(crc oc-env); OUTPUT_DIR="$$(pwd)/out" $(INSTALL_YAMLS_DIR)/devsetup/scripts/gen-ansibleee-ssh-key.sh

	$(info Creating eDPM instance)
	$(eval PCI_DEVICES := $(shell lspci -n -d $(GPU_VENDOR_ID):$(GPU_PRODUCT_ID) | cut -f1 -d' ' | tr '\n' ' '))
	@eval $$(crc oc-env); GPU_IDS="$(GPU_VENDOR_ID):$(GPU_PRODUCT_ID)" EDPM_COMPUTE_VCPUS=$(EDPM_CPUS) EDPM_COMPUTE_RAM=$(EDPM_RAM) EDPM_COMPUTE_DISK_SIZE=$(EDPM_DISK) PCI_DEVICES="$(PCI_DEVICES)" OUTPUT_DIR=$$(realpath ./out/) scripts/gen-edpm-node.sh

	$(info Provisioning eDPM node)
	@eval $$(crc oc-env); DATAPLANE_EXTRA_NOVA_CONFIG_FILE=$$(realpath ./out/nova-compute.conf) DATAPLANE_TIMEOUT=$(TIMEOUT_EDPM) DATAPLANE_TOTAL_NODES=1 make -C $(INSTALL_YAMLS_DIR) edpm_wait_deploy

.PHONY: deploy_rhel_ai
deploy_rhel_ai: ## Deploy RHEL AI on RHOSO
	$(eval $(call vars))
ifeq (,$(wildcard out/rhel-ai-disk.qcow2))
        ifeq ($(AI_IMAGE_URL),)
		$(error Please go to https://access.redhat.com/downloads/content/932 , copy the link to the qcow2 download, and pass it in the AI_IMAGE_URL env var or manually download it to out/rhel-ai-disk.qcow2)
        else
		$(info Downloading RHEL AI image)
		@curl -Lo out/rhel-ai-disk.qcow2 "$(AI_IMAGE_URL)"
        endif
else
	$(info RHEL AI image already present in the system)
endif
	@scripts/http-serve.sh start

ifeq ($(GPU_PRODUCT_ID),)
	$(eval GPU_PRODUCT_ID := $(shell lspci -n  |grep $(GPU_VENDOR_ID) | cut -f3 -d' '| cut -f2 -d: | head -n1))
endif
ifeq ($(AI_NUM_GPUS),all)
	$(eval AI_NUM_GPUS := $(shell lspci -n -d $(GPU_VENDOR_ID):$(GPU_PRODUCT_ID) | wc -l))
endif

	$(info Deploying RHEL AI on RHOSO)
	@eval $$(crc oc-env) && \
	oc cp scripts/edpm-deploy-rhel-ai.sh openstackclient:/tmp/ && \
	oc cp $(PULL_SECRET) openstackclient:/home/cloud-admin/pull-secret && \
	oc rsh openstackclient bash -c "NUM_GPUS=$(AI_NUM_GPUS) VM_NAME=$(AI_VM_NAME) CPUS=$(AI_CPUS) RAM=$$((1024*$(AI_RAM))) DISK=$(AI_DISK) /tmp/edpm-deploy-rhel-ai.sh"
	@scripts/http-serve.sh stop

##@ CLEANUP

.PHONY: cleanup_controlplane
cleanup_controlplane: ## Delete the OCP cluster
	@echo Destroying OCP cluster && \
	make -C $(INSTALL_YAMLS_DIR)/devsetup crc_attach_default_interface_cleanup crc_cleanup

.PHONY: cleanup_edpm
cleanup_edpm: ## Delete the eDPM node
	@eval $$(crc oc-env) && \
	( [[ "$(OCP_DOWN)" == "true" ]] || OUTPUT_DIR=$$(realpath ./out/) make -C $(INSTALL_YAMLS_DIR) edpm_deploy_cleanup ) && \
	OUTPUT_DIR=$$(realpath ./out/) make -C $(INSTALL_YAMLS_DIR)/devsetup edpm_compute_cleanup && \
	( [[ "$(OCP_DOWN)" == "true" ]] || oc rsh openstackclient bash -c 'openstack network agent list --host edpm-compute-0.ctlplane.example.com -c ID -f value | xargs openstack network agent delete' )

.PHONY: cleanup_rhel_ai
cleanup_rhel_ai: ## Delete the RHEL AI instance running in RHOSO
	@scripts/http-serve.sh stop
	@source $$(crc oc-env) && \
	oc rsh openstackclient openstack server delete nvidia
