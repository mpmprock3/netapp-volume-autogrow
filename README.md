# NetApp Volume Autogrow - Ansible Automation

Ansible automation for discovering and growing NetApp ONTAP Trident PVC volumes that need autogrow attention. Designed to run from **Ansible Automation Platform (AAP 2.4, RPM-based)** or as an **OpenShift CronJob**.

## What It Does

A two-stage workflow that manages NetApp storage volumes:

1. **Filter (Discovery)** - Finds Trident PVC volumes on a NetApp SVM where:
   - Volume name starts with `trident_pvc`
   - Autosize mode is `off`
   - Size is under the configured threshold (default: 100 GB)

2. **Grow (Modification)** - For each matching volume:
   - Enables `grow_shrink` autosize mode
   - Sets max-autosize to `current_size + 50%` (configurable)
   - Validates the change was applied
   - Sends a CSV report via email

```
┌──────────────────┐     ┌──────────────┐     ┌──────────────────┐
│  Job 1: Filter   │────>│   Approval   │────>│  Job 2: Grow     │
│  (Discovery)     │     │   Node       │     │  (Modification)  │
└──────────────────┘     └──────────────┘     └──────────────────┘
```

## Project Structure

```
netapp-volume-autogrow/
├── playbooks/
│   ├── netapp_volume_filter.yml      # Stage 1: discover volumes
│   └── netapp_volume_grow.yml        # Stage 2: grow volumes
├── roles/
│   └── netapp_volume_manager/
│       ├── defaults/main.yml         # configurable defaults
│       ├── tasks/
│       │   ├── main.yml              # action routing (filter/grow)
│       │   ├── preflight.yml         # connectivity checks
│       │   ├── filter_volumes.yml    # volume discovery logic
│       │   ├── grow_volumes.yml      # volume growth logic
│       │   ├── validate_growth.yml   # post-growth validation
│       │   └── report.yml            # CSV + email report
│       ├── templates/
│       │   ├── email_body.html.j2    # email notification template
│       │   └── volume_report.csv.j2  # CSV report template
│       ├── handlers/main.yml
│       └── meta/main.yml
├── inventory/
│   ├── production/
│   │   ├── hosts.yml
│   │   └── group_vars/all/
│   │       ├── netapp.yml            # connection + threshold settings
│   │       └── vault.yml             # encrypted credentials
│   └── staging/                      # same structure as production
├── openshift/
│   ├── cronjob.yml                   # CronJob to run from OpenShift
│   ├── secret-vault-password.yml     # example Secret template
│   └── kustomization.yml             # deploy with: oc apply -k openshift/
├── aap/
│   ├── credential_types/netapp_ontap.yml   # AAP custom credential type
│   └── workflow_templates/volume_autogrow.yml  # AAP workflow setup guide
├── execution-environment/
│   ├── execution-environment.yml     # EE build definition
│   ├── requirements.yml              # Ansible collections for EE
│   └── requirements.txt              # Python packages for EE
├── collections/requirements.yml      # required Ansible collections
├── ansible.cfg                       # Ansible configuration
├── ansible-pod.yaml                  # ad-hoc debug pod for OpenShift
└── Makefile                          # lint, syntax-check, build-ee, vault ops
```

## Prerequisites

- Ansible Core >= 2.15
- Python packages: `netapp-lib`, `netapp-ontap`
- NetApp ONTAP cluster with REST API enabled
- An SVM-scoped or admin user with volume management permissions

### Install Dependencies

```bash
# Install required Ansible collections
make install-collections

# Or manually
ansible-galaxy collection install -r collections/requirements.yml --force
```

## Configuration

### 1. Set NetApp Connection Details

Edit `inventory/production/group_vars/all/netapp.yml`:

```yaml
netapp_hostname: "storage.example.com"
netapp_target_svm: "SVM_Name"
netapp_volume_size_threshold_gb: 100
netapp_volume_name_prefix: "trident_pvc"
netapp_volume_growth_percent: 50
```

### 2. Set Credentials

Edit and encrypt `inventory/production/group_vars/all/vault.yml`:

```bash
# Edit the vault file
vi inventory/production/group_vars/all/vault.yml
```

Set the values:

```yaml
vault_netapp_username: "your_ontap_user"
vault_netapp_password: "your_ontap_password"
```

Then encrypt:

```bash
make encrypt-vault
# or
ansible-vault encrypt inventory/production/group_vars/all/vault.yml
```

### 3. Configure Email (Optional)

In `inventory/production/group_vars/all/netapp.yml`:

```yaml
smtp_host: "smtp.example.com"
smtp_port: 25
mail_from: "ansible-automation@example.com"
mail_to: "storage-team@example.com"
```

## Running the Playbooks

### Option 1: CLI (Local / Bastion Host)

**Discover volumes (Stage 1):**

```bash
ansible-playbook playbooks/netapp_volume_filter.yml \
  -i inventory/production \
  --ask-vault-pass
```

**Grow volumes (Stage 2) - Dry Run first:**

```bash
ansible-playbook playbooks/netapp_volume_grow.yml \
  -i inventory/production \
  --ask-vault-pass \
  -e netapp_dry_run=true \
  -e '{"volumes": [{"volume": "trident_pvc_xxx", "current_size_gb": 44}]}'
```

**Grow volumes (Stage 2) - Live:**

```bash
ansible-playbook playbooks/netapp_volume_grow.yml \
  -i inventory/production \
  --ask-vault-pass \
  -e '{"volumes": [{"volume": "trident_pvc_xxx", "current_size_gb": 44}]}'
```

### Option 2: OpenShift CronJob

Run the playbooks on a schedule directly from OpenShift (useful when the NetApp SVM is only reachable from the cluster network).

**Setup:**

```bash
# 1. Create namespace
oc new-project ansible-automation

# 2. Create the vault password secret
oc create secret generic netapp-vault-password \
  --from-literal=password='YOUR_VAULT_PASSWORD'

# 3. Edit the git repo URL in openshift/cronjob.yml
#    Update GIT_REPO_URL to point to your repository

# 4. (Private repo only) Create git credentials secret
oc create secret generic git-credentials \
  --from-literal=username='YOUR_GIT_USER' \
  --from-literal=token='YOUR_GIT_TOKEN'
#    Then uncomment the GIT_USERNAME/GIT_TOKEN env vars in openshift/cronjob.yml

# 5. Deploy the CronJob
oc apply -k openshift/
```

**Operations:**

```bash
# Trigger an immediate ad-hoc run
oc create job --from=cronjob/netapp-volume-autogrow netapp-manual-$(date +%s)

# Watch logs of a running job
oc logs -f job/netapp-manual-<timestamp>

# Check CronJob status
oc get cronjob netapp-volume-autogrow

# List recent job runs
oc get jobs -l app.kubernetes.io/name=netapp-volume-autogrow

# Suspend the CronJob
oc patch cronjob netapp-volume-autogrow -p '{"spec":{"suspend":true}}'

# Resume the CronJob
oc patch cronjob netapp-volume-autogrow -p '{"spec":{"suspend":false}}'
```

The CronJob runs **weekly on Sunday at 02:00 AM** by default. Change the schedule in `openshift/cronjob.yml` under `spec.schedule`.

**CronJob configuration (env vars in `openshift/cronjob.yml`):**

| Variable | Default | Description |
|---|---|---|
| `GIT_REPO_URL` | *(must set)* | Git repository URL to clone |
| `GIT_BRANCH` | `main` | Branch to clone |
| `ANSIBLE_INVENTORY_ENV` | `production` | Inventory environment to use |
| `NETAPP_DRY_RUN` | `false` | Set to `true` for safe test runs |

### Option 3: Ansible Automation Platform (AAP 2.4 RPM-based)

This project is designed for AAP 2.4 installed via RPM on RHEL (not the OpenShift Operator-based installation). The Automation Controller web UI is used to configure all components.

**Step 1: Build and push the Execution Environment**

AAP 2.4 requires an EE image with the NetApp collections and Python dependencies baked in. Build it and push to your Private Automation Hub or a container registry accessible by the controller:

```bash
# Build the EE image
make build-ee

# Tag and push to your Private Automation Hub registry
podman tag netapp-volume-ee:latest hub.example.com/ee-images/netapp-volume-ee:latest
podman push hub.example.com/ee-images/netapp-volume-ee:latest
```

**Step 2: Create Custom Credential Type**

In the Automation Controller UI:
1. Go to **Administration > Credential Types**
2. Click **Add** and configure using the input/injector spec from `aap/credential_types/netapp_ontap.yml`
3. This maps `netapp_hostname`, `netapp_username`, `netapp_password`, `netapp_target_svm`, and `netapp_validate_certs` as extra vars injected into playbook runs

**Step 3: Create a Credential**

1. Go to **Resources > Credentials**
2. Click **Add**, select the **NetApp ONTAP** credential type created above
3. Fill in your ONTAP cluster hostname, SVM name, username, and password

**Step 4: Create the Project**

1. Go to **Resources > Projects**
2. Click **Add**:
   - **Name**: `NetApp Volume Management`
   - **Source Control Type**: Git
   - **Source Control URL**: your repo URL
   - **Source Control Branch**: `main`
   - **Execution Environment**: `netapp-volume-ee` (the EE you pushed in Step 1)
3. Sync the project

**Step 5: Create Job Templates**

Create two Job Templates:

**Job Template 1 — Filter:**
1. Go to **Resources > Templates > Add > Job Template**
   - **Name**: `NetApp Volume Filter`
   - **Project**: `NetApp Volume Management`
   - **Playbook**: `playbooks/netapp_volume_filter.yml`
   - **Inventory**: your inventory (or use the bundled one)
   - **Credentials**: attach the NetApp ONTAP credential
   - **Execution Environment**: `netapp-volume-ee`
   - **Extra Variables**:
     ```yaml
     netapp_volume_size_threshold_gb: 100
     netapp_volume_name_prefix: "trident_pvc"
     ```

**Job Template 2 — Grow:**
1. Go to **Resources > Templates > Add > Job Template**
   - **Name**: `NetApp Volume Grow`
   - **Project**: `NetApp Volume Management`
   - **Playbook**: `playbooks/netapp_volume_grow.yml`
   - **Inventory**: your inventory
   - **Credentials**: attach the NetApp ONTAP credential
   - **Execution Environment**: `netapp-volume-ee`
   - **Extra Variables**:
     ```yaml
     netapp_volume_growth_percent: 50
     netapp_dry_run: false
     ```

**Step 6: Create Workflow Job Template**

1. Go to **Resources > Templates > Add > Workflow Job Template**
   - **Name**: `NetApp Volume Autogrow`
2. Open the **Visualizer** and build the workflow:
   ```
   [Filter] --success--> [Approval Node] --approved--> [Grow]
   ```
   - **Node 1**: Job Template `NetApp Volume Filter` (start node)
   - **Node 2**: Approval Node — name: `Review Volume Growth Plan`, timeout: 3600s
   - **Node 3**: Job Template `NetApp Volume Grow` (on approval)
3. The `volumes` variable passes automatically from Filter to Grow via `set_stats` artifact
4. **Optional**: Add a **Schedule** (e.g., weekly Sunday 02:00 AM) under the workflow template's **Schedules** tab
5. **Optional**: Configure **Notifications** (Slack, Email) under the **Notifications** tab

See `aap/workflow_templates/volume_autogrow.yml` for the full workflow structure reference.

## Configurable Parameters

| Parameter | Default | Description |
|---|---|---|
| `netapp_volume_size_threshold_gb` | `100` | Only process volumes under this size |
| `netapp_volume_name_prefix` | `trident_pvc` | Volume name prefix filter |
| `netapp_volume_growth_percent` | `50` | Percentage to grow volume max-autosize |
| `netapp_volume_autosize_target_mode` | `grow_shrink` | ONTAP autosize mode to set |
| `netapp_dry_run` | `false` | Preview changes without modifying |
| `netapp_validate_after_grow` | `true` | Validate changes post-growth |
| `netapp_max_volumes_per_run` | `200` | Safety cap on volumes per execution |
| `netapp_retry_count` | `3` | API call retry attempts |
| `netapp_throttle` | `10` | Max concurrent ONTAP API calls |

## Development

```bash
# Lint playbooks and roles
make lint

# Syntax check
make syntax-check

# Build Execution Environment image
make build-ee

# Decrypt vault for editing
make decrypt-vault

# Re-encrypt vault after editing
make encrypt-vault
```

## Execution Environment

AAP 2.4 (RPM-based) uses Execution Environments to provide isolated, containerized runtime for playbooks. Build the EE and push it to your Private Automation Hub or a container registry accessible by the controller:

```bash
# Build the EE image
make build-ee
# Builds: netapp-volume-ee:latest

# Tag and push to Private Automation Hub (adjust the registry URL)
podman tag netapp-volume-ee:latest hub.example.com/ee-images/netapp-volume-ee:latest
podman push hub.example.com/ee-images/netapp-volume-ee:latest
```

Then register it in Automation Controller:
1. Go to **Administration > Execution Environments > Add**
2. Set the image URL to match your registry path
3. Assign it to your Project and Job Templates

The EE includes:
- `netapp.ontap` Ansible collection
- `community.general` and `ansible.utils` collections
- Python packages: `netapp-lib`, `netapp-ontap`
