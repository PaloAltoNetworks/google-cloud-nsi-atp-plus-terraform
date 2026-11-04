# Terraform Deployment Guide for Frontier Virtual Patching with Network Security Integration


This tutorial shows how to deploy Palo Alto Networks Software Firewalls in Google Cloud, utilizing either the *in-line* or *out-of-band* deployment model within the [Network Security Integration](https://cloud.google.com/network-security-integration/docs/nsi-overview) (NSI), and how to enable **Advanced Threat Prevention Plus (ATP Plus)** with **Frontier Virtual Patching (FVP)** on the deployed NGFWs.  NSI enables you to gain visibility and security for your VPC network traffic, without requiring any changes to your network infrastructure.  Frontier Virtual Patching extends the firewall's inline protections by proactively discovering unknown vulnerabilities and preemptively shielding them before official vendor patches are available.  

The functionality of each model is summarized as follows:

| Model           | Description             |
| --------------- | ----------------------- |
| **Out-of-Band** | Uses packet mirroring to forward a copy of network traffic to Software Firewalls for *out-of-band* inspection. Traffic is mirrored to your software firewalls by creating mirroring rules within your network firewall policy. |
| **In-line**     | Uses packet intercept to steer network traffic to Software Firewalls for *in-line* inspection. Traffic is steered to your software firewalls by creating firewall rules within your network firewall policy. |

This tutorial is intended for network administrators, solution architects, and security professionals who are familiar with [Compute Engine](https://cloud.google.com/compute) and [Virtual Private Cloud (VPC) networking](https://cloud.google.com/vpc).


<br>

## Architecture

NSI follows a *producer-consumer* model, where the *consumer* consumes services provided by the *producer*. The *producer* contains the cloud infrastructure responsible for inspecting network traffic, while the *consumer* environment contains the cloud resources that require inspection.

The end-to-end architecture — the NSI producer/consumer firewalls on Google Cloud combined with Advanced Threat Prevention Plus (ATP Plus) and Frontier Virtual Patching (FVP) — is shown below:

<img src="images/atpp.png" width="100%">

The underlying NSI traffic-steering model between the consumer and producer is shown below:

<img src="images/diagram.png" width="100%">

### Frontier Virtual Patching

**Frontier Virtual Patching (FVP)** is the capability added by the **Advanced Threat Prevention Plus (ATP Plus)** subscription. It delivers cloud-based, *pre-disclosure* vulnerability protection: the firewall preemptively shields your workloads against vulnerabilities **weeks or months before** they are publicly disclosed or an official vendor patch exists. FVP complements the real-time, inline detection of Advanced Threat Prevention (ATP) — together they close the "dual exposure gap" between when a vulnerability becomes exploitable and when it is patched.

**How it works**

1. **Proactive discovery** — [NOVA](https://www.paloaltonetworks.com/blog/network-security/harnessing-ai-for-prevention-introducing-frontier-virtual-patching/) (the Network and Open-Source Vulnerability Analyzer, powered by Frontier AI) automatically discovers, validates, and reports previously unknown vulnerabilities across open-source and closed-source software before threat actors find them.
2. **Pre-disclosure intelligence** — the [Critical Defense Program (CDP)](https://www.paloaltonetworks.com/critical-defense-program) securely shares embargoed vulnerability intelligence from software vendors, enabling coordinated network-level "virtual patches" (also called *air cover*).
3. **Preemptive protections** — validated protections are published to the **Frontier Virtual Patching cloud service** and streamed to the firewall (typically within hours of discovery) using *Vaulted Protection* technology, so they are in place before public disclosure.
4. **Inline enforcement** — the NGFW applies these protections inline through a **Vulnerability Protection profile** (with the Frontier Virtual Patching settings enabled) that is attached to your security policy rules, blocking exploitation attempts in real time.

**How to achieve it**

To enable FVP on the deployed NGFWs:

1. Activate the **ATP Plus (ATP+)** subscription license on the firewall. Once active, a **Frontier Virtual Patching** tab becomes available in the Vulnerability Protection profile.
2. Ensure the firewall is running **PAN-OS 12.2.4 or later**.
3. Update the content release version to **9157-10279 or later**.
4. Verify that **Advanced Forwarding** is active on the firewall (enabled by default on PAN-OS 12.2.2 and later). See [Configure Advanced Forwarding Settings](https://docs.paloaltonetworks.com/advanced-threat-prevention/getting-started/configure-advanced-forwarding-settings).
5. Configure **Frontier Virtual Patching** within a Vulnerability Protection profile and apply that profile via a security policy rule.

> [!TIP]
> For the full, screenshot-driven walkthrough of licensing, activation, and configuring the NGFW for ATP Plus / Frontier Virtual Patching, see [Configure the NGFW for ATP Plus (Frontier Virtual Patching)](#configure-the-ngfw-for-atp-plus-frontier-virtual-patching) later in this guide.

### Producer Components

The producer creates firewalls which serve as the backend service for an internal load balancer. For each zone requiring traffic inspection, the producer creates a forwarding rule, and links it to an *intercept* or *mirroring* *deployment* which is a zone-based resource. These are consolidated into an *deployment group*, which is then made accessible to the consumer.

| Component | Description |
| :---- | :---- |
| [Load Balancer](https://cloud.google.com/network-security-integration/docs/out-of-band/configure-producer-service#create-int-lb-pm) | An internal network load balancer that distributes traffic to the NGFWs. |
| [Deployments](https://cloud.google.com/network-security-integration/docs/out-of-band/deployments-overview) | A zonal resource that acts as a backend of the load balancer, providing network inspection on traffic from the consumer. |
| [Deployment Group](https://cloud.google.com/network-security-integration/docs/out-of-band/deployment-groups-overview) | A collection of intercept or mirroring deployments that are set up across multiple zones within the same project.  It represents the firewalls as a service that consumers reference. |
| [Instance Group](https://cloud.google.com/compute/docs/instance-groups) | A managed or unmanaged instance group that contains the firewalls which enable horizontal scaling. |


#### Zone Affinity Considerations

The internal load balancer now supports Google Cloud's [**zonal affinity**](https://cloud.google.com/load-balancing/docs/internal/zonal-affinity) feature on its regional backend service, which lets you keep inspection traffic within the consumer's source zone (and control how it spills over to other zones). This Terraform plan creates **one forwarding rule per zone** in the region and links each to its own zonal intercept/mirroring **deployment**, so that every zone has a dedicated, zone-local inspection path. All zonal deployments are aggregated into a single global **deployment group**.

Zonal affinity is configured on the backend service through the following producer variables:

| Variable | Description | Default |
| :---- | :---- | :---- |
| `zonal_affinity_spillover` | Zonal affinity mode. One of `ZONAL_AFFINITY_DISABLED`, `ZONAL_AFFINITY_STAY_WITHIN_ZONE`, or `ZONAL_AFFINITY_SPILL_CROSS_ZONE`. | `ZONAL_AFFINITY_SPILL_CROSS_ZONE` |
| `zonal_affinity_spillover_ratio` | Threshold (`0.0`–`1.0`) for keeping traffic in the client's zone. Only applies when `zonal_affinity_spillover = ZONAL_AFFINITY_SPILL_CROSS_ZONE`. When the proportion of healthy, eligible backends in the client's zone drops below this value, new connections spill over to other zones. | `0.8` |

The supported modes map to the following deployment behaviors:

* **`ZONAL_AFFINITY_STAY_WITHIN_ZONE`** (zone-based): Traffic is always inspected by a firewall in the same zone as the consumer's source zone, and is dropped within the zone rather than spilling over.
* **`ZONAL_AFFINITY_SPILL_CROSS_ZONE`** (zone-based with spillover): Traffic is kept local while enough healthy backends exist in the zone; once the healthy-backend proportion falls below `zonal_affinity_spillover_ratio`, new connections spill over to firewalls in other zones within the region.
* **`ZONAL_AFFINITY_DISABLED`** (cross-zone): Traffic may be inspected by any firewall within the same region as the traffic's source (the previous behavior).

This deployment uses a **cross-zone architecture with zonal affinity enabled**, which is the recommended option and the default configured by this Terraform plan (<code>ZONAL_AFFINITY_SPILL_CROSS_ZONE</code>). Traffic is inspected by a firewall in the consumer's own zone whenever healthy backends are available there, and automatically spills over to firewalls in other zones within the region when they are not — combining the low latency of zone-local inspection with the resilience of a regional firewall fleet.

<table>
  <tr>
    <!-- Title cell with left alignment -->
    <th colspan="2" align="left">Cross-Zone Deployment (zonal affinity enabled) &mdash; recommended</th>
  </tr>
  <tr>
    <td width="35%"><img src="images/diagram_region.png" width="100%"></td>
    <td width="65%">
      <ol>
        <li>Deploy the firewalls to a regional instance group that spans every zone in the region.</li>
        <li>Add the instance group to a backend service and enable <b>zonal affinity</b> (<code>zonal_affinity_spillover = ZONAL_AFFINITY_SPILL_CROSS_ZONE</code>), so traffic stays zone-local but can spill cross-zone when needed.</li>
        <li>Create a forwarding rule per zone targeting the backend service.</li>
        <li>Link each forwarding rule to an intercept/mirroring deployment that matches the zone you are inspecting.</li>
        <li>Aggregate all zonal deployments into a single deployment group.</li>
      </ol>
      <i>Terraform performs steps 3-5 automatically for every zone in <code>var.region</code>.</i>
    </td>
  </tr>
</table>

> [!NOTE]
> A forwarding rule is created for every zone in the region, each consuming one IP from `subnet_cidr_data` starting at host offset `.11`. The default `/28` dataplane subnet supports standard 3-4 zone regions; widen `subnet_cidr_data` if your region has more zones.

<br>

### Consumer Components

The consumer creates an *intercept* or *mirroring* *endpoint group* corresponding to the producer's *deployment group*. Then, the consumer associates the endpoint group with VPC networks requiring inspection. 

Finally, the consumer creates a network firewall policy with rules that use a *security profile group* as their action.  Traffic matching these rules is intercepted or mirrored to the producer for inspection.

| Component | Description |
| :---- | :---- |
| [Endpoint Group](https://cloud.google.com/network-security-integration/docs/out-of-band/endpoint-groups-overview) | A project-level resource that directly corresponds to a producer's deployment group. This group can be associated with multiple VPC networks. |
| [Endpoint Group Association](https://cloud.google.com/network-security-integration/docs/out-of-band/configure-mirroring-endpoint-group-associations) | Associates the endpoint group to consumer VPCs. |
| [Firewall Rules](https://cloud.google.com/firewall/docs/network-firewall-policies) | Exists within Network Firewall Policies and select traffic to be intercepted or mirrored for inspection by the producer. |
| [Security Profiles](https://cloud.google.com/network-security-integration/docs/security-profiles-overview) | Can be type `intercept` or `mirroring` and are set as the action within firewall rules. |

<br>

### Traffic Flow Example

The network firewall policy associated with the `consumer-vpc` contains two rules, each specifying a security profile group as their action. When traffic matches either rule, the traffic is encapsulated to the producer for inspection. Both rules and the security profile group are created automatically by Terraform.

<table>
  <tr>
    <!-- Title cell with left alignment -->
    <th colspan="5" align="center">Network Firewall Policy</th>
  </tr>
    <tr>
        <th>PRIORITY</th>
        <th>DIRECTION</th>
        <th>SOURCE</th>
        <th>DESTINATION</th>
        <th>ACTION</th>
    </tr>
    <tr>
        <td><code>10</code></td>
        <td><code>Egress</code></td>
        <td><code>0.0.0.0/8</code></td>
        <td><code>0.0.0.0/0</code></td>
        <td><code>apply-security-profile</code></td>
    </tr>
    <tr>
        <td><code>11</code></td>
        <td><code>Ingress</code></td>
        <td><code>0.0.0.0/0</code></td>
        <td><code>0.0.0.0/8</code></td>
        <td><code>apply-security-profile</code></td>
    </tr>
</table>

> [!NOTE]
> In the *out-of-band* model, traffic would be mirrored to the firewalls instead of redirected.  


#### Traffic to Producer
<img src="images/diagram_flow1.png" width="100%">

1. The `web-vm` makes a request to the internet. The request is evaluated against the rules within the Network Firewall Policy associated with the `consumer-vpc`.
2. The request matches the `EGRESS` rule (priority: `10`) that specifies a security profile group as its action.
3. The request is then encapsulated through the `endpoint association` to the producer environment.
4. Within the producer environment, the `intercept deployment group` directs traffic to the `intercept deployment` located in the same zone as the `web-vm`.
5. The internal load balancer forwards the traffic to an available firewall for deep packet inspection.

#### Traffic from Producer
<img src="images/diagram_flow2.png" width="100%">

1. If the firewall permits the traffic, it is returned to the `web-vm` via the consumer's `endpoint association`.
2. The local route table of the `consumer-vpc` routes traffic to the internet via the Cloud NAT.
3. The session is established with the internet destination and is continuously monitored by the firewall. 

---

<br>

## Requirements


1. A Google Cloud project.
2. Access to [Cloud Shell](https://shell.cloud.google.com). 
3. The following IAM Roles:

    | Ability | Scope | Roles |
    | :---- | :---- | :---- |
    | Create [firewall endpoints](https://cloud.google.com/firewall/docs/about-firewall-endpoints#iam-roles), [endpoint associations](https://cloud.google.com/firewall/docs/about-firewall-endpoints#endpoint-association), [security profiles](https://cloud.google.com/firewall/docs/about-security-profiles#iam-roles), and [network firewall policies](https://cloud.google.com/firewall/docs/network-firewall-policies#iam). | Project | `compute.networkAdmin`<br>`compute.networkUser`<br>`compute.networkViewer` |
    | Create [global network firewall policies](https://cloud.google.com/firewall/docs/use-network-firewall-policies#expandable-1) and [firewall rules](https://cloud.google.com/firewall/docs/use-network-firewall-policies#expandable-8) for VPC networks. | Project | `compute.securityAdmin`<br>`compute.networkAdmin`<br>`compute.networkViewer`<br>`compute.viewer`<br>`compute.instanceAdmin` |


<br>

## Create Producer Environment
In the `producer` directory, use the terraform plan to automatically create the producer's VPCs, instance template, instance group, internal load balancer, NSI intercept deployment group, and NSI intercept deployment.

> [!TIP]
> In production environments, it is recommended to deploy the producer resources to a dedicated project.  This ensures the security services are managed independently of the consumer.

> [!CAUTION]
> It is required to make your cloudshell git support large file download, run below command to install git lfs before you start to clone the source code.
  
    sudo apt install git-lfs


1. In [Cloud Shell](https://shell.cloud.google.com), clone the repository change to the `producer` directory. 

    ```
    git clone https://github.com/PaloAltoNetworks/google-cloud-nsi-atp-plus-terraform.git
    cd google-cloud-nsi-ui-demo/producer
    ```

2. Create a `terraform.tfvars`.

    ```
    cp terraform.tfvars.example terraform.tfvars
    ```

3. Edit `terraform.tfvars` by setting values for the following variables:  
   
    | Key | Value | Default |
    | :---- | :---- | :---- |
    | `project_id` | The Google Cloud project ID of the producer environment. | `null` |
    | `mgmt_allow_ips` | A list of IPv4 addresses which have access to the firewall's mgmt interface. | `["0.0.0.0/0"]` |
    | `mgmt_public_ip` | If true, the management address will have a public IP assigned to it. | `true` | 
    | `region` | The region to deploy the consumer resources. | `us-west1` |
    | `image_name` | The firewall image to deploy. | `vmseries-flex-bundle2-1126`|
    | `mirroring_mode` | If true, configures the forwarding rule for packet mirroring. If false, configures it for in-band traffic. | `false` |


> [!CAUTION]
> It is recommended to set `mgmt_public_ip` to `false` in production environments.

> [!TIP]
> For `image_name`, a full list of public images can be found with this command:
> ```
> gcloud compute images list --project paloaltonetworksgcp-public --no-standard-images
> ```
> All NSI deployments require PAN-OS 11.2.x or greater.

> [!NOTE]
> If you are using BYOL image (i.e.  <code>vmseries-flex-<b>byol</b>-*</code>), the license can be applied during or after deployment.  To license during deployment, add your authcode to `bootstrap_files/authcodes`.  See [Bootstrap Methods](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-deployment/bootstrap-the-vm-series-firewall) for more information.  


4. Initialize and apply the terraform plan.

    ```
    terraform init
    terraform apply
    ```

    Enter `yes` to apply the plan.

5. After the apply completes, terraform displays the following message:

    <pre>
    export <b>PRODUCER_PROJECT</b>=<i>your-project-id</i>
    export <b>DATA_VPC</b>=<i>nsi-data</i>
    export <b>DATA_SUBNET</b>=<i>us-west1-data</i>
    export <b>REGION</b>=<i>us-west1</i>
    export <b>ZONE</b>=<i>us-west1-a</i>
    export <b>BACKEND_SERVICE</b>=<i>https://www.googleapis.com/compute/v1/projects/your-project-id/regions/us-west1/backendServices/panw-nsi-lb</i></pre>


> [!IMPORTANT] 
> The `init-cfg.txt` includes `plugin-op-commands=geneve-inspect:enable` bootstrap parameter, allowing firewalls to handle GENEVE encapsulated traffic forwarded via packet intercept. 
> If this is not configured, packet intercept traffic will be dropped. 

<br>

---

# ***On the Consumer project***

## Create Consumer Environment

In the `consumer` directory, use the terraform plan to create a consumer environment. The terraform plan automatically creates a VPC (`consumer-vpc`), two debian VMs (`client-vm` & `web-vm`), an optional GKE cluster (`cluster1`), as well as the necessary NSI components: Endpoint Group, Endpoint Group Association, Security Profile, Security Profile Group, and Global Network Firewall Policy with rules.

> [!NOTE]
> The Endpoint Group is associated with the Deployment Group created in the Producer project. Ensure you have the producer project ID and deployment group ID from the previous steps.

1. In Cloud Shell, change to the `consumer` directory.

    ```
    cd
    cd google-cloud-nsi-ui-demo/consumer
    ```

2. Create a `terraform.tfvars`

    ```
    cp terraform.tfvars.example terraform.tfvars
    ```

3. Edit `terraform.tfvars` by setting values for the following variables:  
   

    | Variable | Description | Default |
    | :---- | :---- | :---- |
    | `project_id` | The project ID of the consumer environment. | `null` |
    | `mgmt_allowed_ips` | A list of IPv4 addresses that can access the VMs on `TCP:80,22`. | `["0.0.0.0/0"]` |
    | `region` | The region to deploy the consumer resources. | `us-west1` |
    | `create_gke` | Whether to create the GKE cluster. | `true` |
    | `producer_project_id` | The project ID of the producer environment. Only used when `deployment_group` is empty. | `null` |
    | `deployment_group_id` | The ID of the deployment group created in the producer project. Only used when `deployment_group` is empty. | `deployment-group` |
    | `deployment_group` | The full resource path of the producer's deployment group (the `$DEPLOYMENT_GROUP` value exported by the producer). When set, it is used directly. | `""` |

4. (Optional) Instead of hand-editing the producer connection values, reuse the environment variables exported by the producer's `terraform output`. Paste the producer exports, then bridge the values the consumer needs into Terraform's `TF_VAR_*` variables:

    ```
    # Producer exports (from `terraform output` in the producer directory), e.g.:
    export PRODUCER_PROJECT=your-project-id
    export REGION=us-west1
    export DEPLOYMENT_GROUP=projects/your-project-id/locations/global/interceptDeploymentGroups/demo-deployment-group

    # Bridge them so Terraform reads them automatically:
    export TF_VAR_producer_project_id="$PRODUCER_PROJECT"
    export TF_VAR_deployment_group="$DEPLOYMENT_GROUP"
    export TF_VAR_region="$REGION"
    ```

    > [!NOTE]
    > Values provided via `TF_VAR_*` take precedence over the defaults in `variables.tf`. If you also set them in `terraform.tfvars`, the `.tfvars` values win, so leave the producer connection values unset in `terraform.tfvars` when using this method.

5. Initialize and apply the terraform plan.

    ```
    terraform init
    terraform apply
    ```

    Enter `yes` to apply the plan.

6. After the apply completes, terraform displays the following message:

    <pre>
    export <b>CONSUMER_PROJECT</b>=<i>your-project-id</i>
    export <b>CONSUMER_VPC</b>=<i>consumer-vpc</i>
    export <b>REGION</b>=<i>us-west1</i>
    export <b>ZONE</b>=<i>s-west1-a</i>
    export <b>CLIENT_VM</b>=<i>client-vm</i>
    export <b>CLUSTER</b>=<i>cluster1</i></pre>

<br>



# Configure the NGFW for ATP Plus (Frontier Virtual Patching)

Advanced Threat Prevention Plus (ATP Plus) adds **Frontier Virtual Patching (FVP)** to the firewall by enabling the **Advanced Forwarding** mode. Frontier Virtual Patching proactively discovers previously unknown vulnerabilities and preemptively protects them from exploitation before official vendor patches are available, extending the firewall's inline Advanced Threat Prevention protections. The following steps show how to license and configure a Software NGFW (VM-Series) so it works with ATP Plus. These steps are performed directly on the firewall (PAN-OS) and the Customer Support Portal / SCM — they are independent of the Terraform deployment above.

> [!NOTE]
> ATP Plus includes Advanced Threat Prevention (ATP) capabilities in addition to FVP. On a deployment profile, only **one** of "Advanced Threat Prevention" or "Advanced Threat Prevention Plus" can be selected at a time. FVP/Advanced Forwarding settings require **PAN-OS 12.2.4 or later**.

<br>

## 1. Acquire the ATP Plus Subscription

* On a **hardware appliance**, acquire a trial license for ATP Plus by following this [KB article](https://knowledgebase.paloaltonetworks.com/articles/en_US/Knowledge/How-to-Activate-Trial-Licenses).
* On a **VM-Series firewall**, [edit the deployment profile](https://docs.paloaltonetworks.com/vm-series/10-1/vm-series-deployment/license-the-vm-series-firewall/software-ngfw/manage-a-deployment-profile) and select **"Advanced Threat Prevention Plus"**. Make sure you **uncheck "Advanced Threat Prevention"**, because only one can be selected. ATP Plus includes ATP as well, along with the FVP capability. See the example below:

<img src="images/atp_deployment_profile.png" width="100%">

<br>

## 2. Activate the ATP Plus Subscription License

* For new devices, [install the device certificate](https://docs.paloaltonetworks.com/ngfw/administration/certificate-management/certificate-deployment/install-device-certificate).
* Activate the ATP Plus subscription license by following this [Tech Doc](https://docs.paloaltonetworks.com/ngfw/getting-started/ngfw-compatible-subscriptions/activate-subscription-licenses).

<img src="images/atp_activate_license.png" width="100%">

* Now onboard this firewall on your SCM tenant.

<br>

## 3. Review the Change in Content Cloud Settings

On the PAN-OS UI, navigate to **DEVICE > Setup > Content-ID** and locate **"Content Cloud Settings"**.

**Pre-12.2.4** — Advanced Threat Prevention (ATP) default settings:

<img src="images/atp_content_cloud_pre1224.png" width="100%">

**12.2.4 and above** — ATP Plus default settings. Notice **"Enable Advanced Forwarding"**:

<img src="images/atp_content_cloud_1224.png" width="100%">

> [!NOTE]
> To learn more about these settings, click "?" at the top right to review the in-product help.

<br>

## 4. Verify the Changes in the Firewall CLI

**Pre-12.2.4** (ATP) — the WildFire upload (`WifUpload`) security client is connected to the cloud and in a ready state:

<img src="images/atp_cli_wifupload_atp.png" width="100%">

**12.2.4** (ATP Plus) — the `WifUpload` security client is disconnected and disabled due to Advanced Forwarding mode:

<img src="images/atp_cli_wifupload_atpplus.png" width="100%">

New FVP-related commands to check the cloud connection status and FVP configuration:

```
admin@PA-VM> show paed
  > cfg-sync-status    Show recent config sync status
  > cloud-status       Show discovery cloud connection status
  > conn-health        Show recent conn health status
  > device-info        Show device info used in discovery
  > discovery-status   Show recent discovery status
  > fqdns              Show current FQDNs
  > jobs               Show paed job history

admin@PA-VM# show deviceconfig setting pae-discovery
```

<br>

## 5. Allow all FVP FQDNs (Optional)

Only for existing ATP configurations in some production deployments — since the FVP FQDNs are different from the ATP FQDNs, ensure that all FQDNs used in the FVP configuration settings shown above are allowed by your existing security policies.

For a more detailed explanation, refer to [Enable Advanced Forwarding](https://docs.paloaltonetworks.com/advanced-threat-prevention/getting-started/configure-advanced-forwarding-settings).

<br>

## 6. Follow the FVP Configuration Steps

For a standalone firewall, the configuration screenshots are given below:

<img src="images/atp_fvp_config_1.png" width="100%">

<img src="images/atp_fvp_config_2.png" width="100%">

<img src="images/atp_fvp_config_3.png" width="100%">

<img src="images/atp_fvp_config_4.png" width="100%">

<br>

## 7. View Threat Events

For a standalone firewall, the equivalent screenshots are given below:

<img src="images/atp_threat_events_1.png" width="100%">

<img src="images/atp_threat_events_2.png" width="100%">

<br>

## 8. Fetch the Cloud Report via Threat Vault API

If you are using the firewall UI, the Cloud Report can be fetched from the Threat Vault API as shown below.

Required information:

* **Threat Vault API Key** (from your support portal account)
* **Cloud Report ID** (from the Threat Log)

<img src="images/atp_cloud_report_api.png" width="100%">

Where can I get the "Threat Vault API Key"?

<img src="images/atp_threat_vault_api_key.png" width="100%">

<br>


# (Optional) Deletion

## On the Consumer Project:

  1. Run `terraform destroy` from the `consumer` directory.

        ```
        cd google-cloud-nsi-ui-demo/consumer
        terraform destroy
        ```

  2. Enter `yes` to delete all consumer resources.

## On the Producer Project:

  1. Run `terraform destroy` from the `producer` directory.

        ```
        cd google-cloud-nsi-ui-demo/producer
        terraform destroy
        ```

  2. Enter `yes` to delete all producer resources.
