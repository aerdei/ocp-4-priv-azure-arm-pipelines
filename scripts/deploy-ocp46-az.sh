#!/bin/bash
set -e
init_working_dir=$(pwd)
cd "$(dirname "$0")" || exit
cluster_install_dir="../installer/cluster-1"

# OCP 4.5 Azure UPI
## Prepare installation files
### Obtain installation program
cd ../installer
wget -N https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.6/openshift-install-linux.tar.gz
tar -xvzf ../installer/openshift-install-linux.tar.gz openshift-install
cd ../scripts

### Set common variables
cluster_name=$(yq -c -r .metadata.name $cluster_install_dir/install-config.yaml)
ssh_key=$(cat ../ssh-keys/id_rsa.pub)
base_domain=$(yq -c -r .baseDomain $cluster_install_dir/install-config.yaml)
network_name=$(yq -c -r .platform.azure.virtualNetwork $cluster_install_dir/install-config.yaml)
network_resource_group=$(yq -c -r .platform.azure.networkResourceGroupName $cluster_install_dir/install-config.yaml)
#base_domain_resource_group=$(yq -c -r .platform.azure.baseDomainResourceGroupName $cluster_install_dir/install-config.yaml)
KUBECONFIG="$cluster_install_dir/auth/kubeconfig"
export KUBECONFIG

### Create manifests
../installer/openshift-install create manifests --dir=$cluster_install_dir

### Set install variables
infra_id=$(yq -c -r .status.infrastructureName $cluster_install_dir/manifests/cluster-infrastructure-02-config.yml)
resource_group=$(yq -c -r .status.platformStatus.azure.resourceGroupName $cluster_install_dir/manifests/cluster-infrastructure-02-config.yml)

### Customize manifests
rm -f $cluster_install_dir/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -f $cluster_install_dir/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
sed -i 's/mastersSchedulable: true/mastersSchedulable: false/g' $cluster_install_dir/manifests/cluster-scheduler-02-config.yml

### Create ignition files
../installer/openshift-install create ignition-configs --dir=$cluster_install_dir

### Create identity and assign contributor role to in deployment and networking namespaces
az deployment group create --template-file "../templates/01_identity.json" --parameters identityName="${infra_id}"-identity --parameters networkResourceGroup="${network_resource_group}" -g "${resource_group}"

### Upload RHCOS images
#### Generate OCP storage account name
ocp_sa_name="${cluster_name}$(cut -c 27- < /proc/sys/kernel/random/uuid)"

#### Create storage resources
az deployment group create -g "${resource_group}" --template-file "../templates/02_storage.json" --parameters ocp_sa_name="${ocp_sa_name}"

#### Export storage account key
account_key=$(az storage account keys list -g "${resource_group}" --account-name "${ocp_sa_name}" --query "[0].value" -o tsv)

#### Choose RHOC version
vhd_url=$(curl -s https://raw.githubusercontent.com/openshift/installer/release-4.6/data/data/rhcos.json | jq -r .azure.url)

#### Copy VHD to blob
az storage blob copy start --account-name "${ocp_sa_name}" --account-key "${account_key}" --destination-blob "rhcos.vhd" --destination-container vhd --source-uri "${vhd_url}"

#### Wait for copy
status="unknown"
while [ "$status" != "success" ]
do
  status=$(az storage blob show --container-name vhd --name "rhcos.vhd" --account-name "${ocp_sa_name}" --account-key "${account_key}" -o tsv --query properties.copy.status)
  echo "$status"
  sleep 60s
done

#### Upload bootstrap ignition config file
az storage blob upload --account-name "${ocp_sa_name}" --account-key "${account_key}" -c "files" -f "$cluster_install_dir/bootstrap.ign" -n "bootstrap.ign"

## Create image, networking, loadbalancing, DNS
### Get VHD blob URL
vhd_blob_url=$(az storage blob url --account-name "${ocp_sa_name}" --account-key "${account_key}" -c vhd -n "rhcos.vhd" -o tsv)

### Create image, networking, loadbalancing, DNS
az deployment group create -g "${resource_group}" --template-file "../templates/03_infra.json" --parameters privateDNSZoneName="${cluster_name}.${base_domain}" --parameters baseName="${infra_id}" --parameters networkResourceGroupName="${network_resource_group}" --parameters virtualNetworkName="${network_name}" --parameters vhdBlobURL="${vhd_blob_url}"

## Create bootstrap machine
### Encode bootstrap variables
bootstrap_url=$(az storage blob url --account-name "${ocp_sa_name}" --account-key "${account_key}" -c "files" -n "bootstrap.ign" -o tsv)
bootstrap_ignition=$(jq -rcnM --arg v "3.1.0" --arg url "${bootstrap_url}" '{ignition:{version:$v,config:{replace:{source:$url}}}}' | base64 -w0)

### Create bootstrap resources
az deployment group create -g "${resource_group}" --template-file "../templates/04_bootstrap.json" --parameters bootstrapIgnition="${bootstrap_ignition}" --parameters sshKeyData="${ssh_key}" --parameters baseName="${infra_id}" --parameters networkResourceGroupName="${network_resource_group}" --parameters virtualNetworkName="${network_name}"

## Create control plane machines
### Encode master ignition
master_ignition=$(base64 -w0 < $cluster_install_dir/master.ign)

### Create control plane resources
az deployment group create -g "${resource_group}" --template-file "../templates/05_masters.json" --parameters masterIgnition="${master_ignition}" --parameters sshKeyData="${ssh_key}" --parameters privateDNSZoneName="${cluster_name}.${base_domain}" --parameters baseName="${infra_id}" --parameters networkResourceGroupName="${network_resource_group}" --parameters virtualNetworkName="${network_name}"

## Create worker machines
### Encode worker ignition
worker_ignition=$(base64 -w0 < $cluster_install_dir/worker.ign)

### Create worker resources
az deployment group create -g "${resource_group}" --template-file  "../templates/06_workers.json" --parameters workerIgnition="${worker_ignition}"  --parameters sshKeyData="${ssh_key}"  --parameters baseName="${infra_id}" --parameters networkResourceGroupName="${network_resource_group}" --parameters virtualNetworkName="${network_name}"

## Download CLI
cd ../installer
wget -N https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.6/openshift-client-linux.tar.gz
tar -xvzf ./openshift-client-linux.tar.gz oc
cd ../scripts

### Approve CSRs
../installer/oc get csr -o go-template --template='{{range .items}}{{if  not .status}}{{printf "%s\n" .metadata.name}}{{end}}{{end}}' | xargs -i ../installer/oc adm certificate approve {}

cd "$init_working_dir"