# OpenShift 4.6 private deployment using ARM templates and Azure Pipelines
An Azure Pipelines driven deployment of an internal OpenShift 4.6 cluster to Azure using ARM templates and an existing VNET relying on user defined routing.

## Prerequisites
* [Azure subscription](portak.azure.com)
* Proper Azure quotas discussed in the [OpenShift documentation](https://docs.openshift.com/container-platform/4.6/installing/installing_azure/installing-azure-account.html#installation-azure-limits_installing-azure-account)

The installation pipeline assumes the following:
* There is a resource group, by default `networking-rg`.
* `networking-rg` contains a VNET, by default `ocp-4-vnet`.
* `ocp-4-vnet` contains two subnets, by default `ocp-4-controlplane-subnet` and `ocp-4-compute-subnet`.
* There is a resource group, by default `openshift-1-rg`, where the OpenShift resources will be deployed.
* There is an Azure Service Principal with Contributor role in both resource groups and User Access Administrator role for assigning roles to the User Assigned Identity later.
* The agent running the deployment is part of `ocp-4-vnet`. More details in the Connectivity section.
* The agent running the deployment has internet connectivity.

## Usage
* Create the resource groups.  
* Create the service principal and the assign the necessary roles.  
* Create a Service connection in Azure Pipelines with the service principal.
* Deploy an Azure Keyvault with the following secrets:  
    - `ocp-4-pullsecret`: Red Hat pull secret for OpenShift deployment
    - `ocp-4-sp-id`: ID of the service principal used for deployment
    - `ocp-4-sp-pw`: Secret of the service principal used for deployment
    - `ocp-4-sp-tid`: Tenant ID of the service principal used for deployment
    - `ocp-4-ssh-pub`: Public SSH key to be deployed to the nodes
* Create a variable group `ocp-4-variable-group` in Azure Pipelines linking to the Azure Keyvault secrets.


## Connectivity
The current deployment assumes no public connectivity to the cluster API and relies on user defined routing. There will be no public endpoints created. This also means that the agent deploying the cluster has to be on the VNET and must be able to resole the Azure Private DNS Zone records.  
It is possible to deploy networking resources that allow connection to the VNET from and node connectivity to the internet. This makes it possible to deploy the cluster and test it without user defined routing or more advanced networking setups in place. To connect to the VNET, do the following:  

Generate certificates for the point-to-site VPN access discussed in the 
[Azure documentation](https://docs.microsoft.com/en-us/azure/vpn-gateway/point-to-site-vpn-client-configuration-azure-cert#generate-certificates-1), for example:
```bash
mkdir azure-gw
sudo strongswan pki --gen --outform pem > ./azure-gw/caKey.pem
sudo strongswan pki --self --in ./azure-gw/caKey.pem --dn "CN=VPN CA" --ca --outform pem > ./azure-gw/caCert.pem
export PASSWORD="password"
export USERNAME="client"
sudo strongswan pki --gen --outform pem > "./azure-gw/${USERNAME}Key.pem"
sudo strongswan pki --pub --in "./azure-gw/${USERNAME}Key.pem" | sudo strongswan pki --issue --cacert ./azure-gw/caCert.pem --cakey ./azure-gw/caKey.pem --dn "CN=${USERNAME}" --san "${USERNAME}" --flag clientAuth --outform pem > "./azure-gw/${USERNAME}Cert.pem"
```
Deploy the `00_networking.json` ARM template that provisions the networking resources mentioned in the Prerequisites section. Make sure to use the CA Certificate generated earlier when provisioning the resources (it will take a minute):
```bash
az deployment group create -g networking-rg --template-file ./templates/00_networking.json --parameters virtualNetworkGatewayP2SRootCert="$(openssl x509 -in ./azure-gw/caCert.pem -outform der | base64 -w0)" --parameters controlPlaneSubnetName="ocp-4-controlplane-subnet" --parameters computeSubnetName="ocp-4-compute-subnet"
```
Deploy the `00_dns_forwarder.json` ARM template that provisions a DNS forwarder which makes it possible to resolve Azure Private DNS Zone records:
```bash
az deployment group create -g networking-rg --template-file ./templates/00_dns_forwarder.json --parameters sshKey="$(cat ./ssh-keys/id_rsa.pub)"
```
Download the Point-to-Site VPN configuration, customize it with the client key and certificate generated earlier. Add the DNS forwarder as DNS server:
```bash
curl -L "$(az network vnet-gateway vpn-client generate -g networking-rg -n ocp-4-vpn | tr -d '\"')" -o azure-gw/vpn.zip
unzip -p azure-gw/vpn.zip 'OpenVPN?vpnconfig.ovpn' | CLIENTCERTIFICATE=$(cat azure-gw/clientCert.pem) PRIVATEKEY=$(cat azure-gw/clientKey.pem) envsubst > azure-gw/azure-p2s.ovpn
```
Import and configure the VPN connection so that DNS search is done on the forwarder IP for your zone and that the connection is only used for resources in Azure:
```bash
nmcli con import type openvpn file ./azure-gw/azure-p2s.ovpn
nmcli con modify azure-p2s ipv4.dns 10.0.5.4
nmcli con modify azure-p2s ipv4.dns-search ${your_dns_zone}
nmcli con modify azure-p2s ipv4.never-default yes
```
Connnect to the P2S VPN and test the connection. You should be able to start the deployment now.
