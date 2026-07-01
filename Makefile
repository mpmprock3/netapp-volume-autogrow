.PHONY: lint syntax-check install-collections build-ee encrypt-vault decrypt-vault clean

INVENTORY ?= inventory/production
EE_IMAGE ?= netapp-volume-ee
EE_TAG ?= latest

install-collections:
	ansible-galaxy collection install -r collections/requirements.yml --force

lint:
	ansible-lint playbooks/ roles/

syntax-check:
	ansible-playbook --syntax-check -i $(INVENTORY) playbooks/netapp_volume_filter.yml
	ansible-playbook --syntax-check -i $(INVENTORY) playbooks/netapp_volume_grow.yml

build-ee:
	ansible-builder build \
		-t $(EE_IMAGE):$(EE_TAG) \
		-f execution-environment/execution-environment.yml \
		-v 3

encrypt-vault:
	ansible-vault encrypt inventory/production/group_vars/all/vault.yml
	ansible-vault encrypt inventory/staging/group_vars/all/vault.yml

decrypt-vault:
	ansible-vault decrypt inventory/production/group_vars/all/vault.yml
	ansible-vault decrypt inventory/staging/group_vars/all/vault.yml

clean:
	find . -name "*.retry" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} +
