# -------------------------------------------------------------------------------------
# Provider configuration
# -------------------------------------------------------------------------------------

terraform {
  required_version = "> 1.5, < 2.0"
  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 6.18 is required for network_pass_through_lb_traffic_policy / zonal_affinity
      # on google_compute_region_backend_service (zonal affinity support).
      version = ">= 6.18, < 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.18, < 8.0"
    }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true

  default_labels = {
    panw = "true"
  }
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true

  default_labels = {
    panw = "true"
  }
}


# -------------------------------------------------------------------------------------
# Localized variables
# -------------------------------------------------------------------------------------

locals {
  prefix                      = var.prefix != null && var.prefix != "" ? "${var.prefix}-" : ""
  public_key_path             = "${path.module}/bootstrap_files/gcp_key.pub"
  create_monitoring_dashboard = true
}


# -------------------------------------------------------------------------------------
# Create management and dataplane VPCs, subnets, and firewall rules.
# -------------------------------------------------------------------------------------

// Create management VPC
resource "google_compute_network" "mgmt" {
  name                    = "${local.prefix}mgmt"
  auto_create_subnetworks = false
}

// Create dataplane VPC
resource "google_compute_network" "data" {
  name                    = "${local.prefix}data"
  auto_create_subnetworks = false
}

// Create management subnet
resource "google_compute_subnetwork" "mgmt" {
  name          = "${local.prefix}${var.region}-mgmt"
  ip_cidr_range = var.subnet_cidr_mgmt
  region        = var.region
  network       = google_compute_network.mgmt.id
}

// Create dataplane subnet
resource "google_compute_subnetwork" "data" {
  name          = "${local.prefix}${var.region}-data"
  ip_cidr_range = var.subnet_cidr_data
  region        = var.region
  network       = google_compute_network.data.id
}

// Firewall rule to allow management access
resource "google_compute_firewall" "mgmt" {
  name          = "${local.prefix}mgmt"
  network       = google_compute_network.mgmt.name
  source_ranges = var.mgmt_allow_ips

  allow {
    protocol = "tcp"
    ports    = ["443", "22", "3978"]
  }
}

// Allow all traffic to firewall's dataplane VPC
resource "google_compute_firewall" "data" {
  name          = "${local.prefix}data"
  network       = google_compute_network.data.name
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
    ports    = []
  }
}

# -------------------------------------------------------------------------------------
#  Create Cloud NAT for management VPC.
# -------------------------------------------------------------------------------------

// Create cloud router for cloud NAT.
resource "google_compute_router" "main" {
  name    = "${local.prefix}${var.region}mgmt-router"
  network = google_compute_network.mgmt.id
  region  = var.region
}

// Create cloud NAT for outbound internet access.
resource "google_compute_router_nat" "main" {
  name                               = "${local.prefix}mgmt-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}


# -------------------------------------------------------------------------------------
#  Create internal load balancer.
# -------------------------------------------------------------------------------------

// Create health check
resource "google_compute_region_health_check" "main" {
  name = "${local.prefix}panw-hc"
  https_health_check {
    port         = 443
    request_path = "/unauth/php/health.php"
  }
}

// Create backend service.
resource "google_compute_region_backend_service" "main" {
  provider      = google-beta
  name          = "${local.prefix}panw-lb"
  protocol      = "UDP"
  network       = google_compute_network.data.id
  health_checks = [google_compute_region_health_check.main.self_link]

  backend {
    group          = google_compute_region_instance_group_manager.main.instance_group
    balancing_mode = "CONNECTION"
  }

  # Zonal affinity keeps inspection traffic within the consumer's source zone.
  # Disabled when zonal_affinity_spillover = ZONAL_AFFINITY_DISABLED.
  dynamic "network_pass_through_lb_traffic_policy" {
    for_each = var.zonal_affinity_spillover == "ZONAL_AFFINITY_DISABLED" ? [] : [1]
    content {
      zonal_affinity {
        spillover       = var.zonal_affinity_spillover
        spillover_ratio = var.zonal_affinity_spillover == "ZONAL_AFFINITY_SPILL_CROSS_ZONE" ? var.zonal_affinity_spillover_ratio : null
      }
    }
  }
}

// Create a forwarding rule for each zone within var.region so each zone has a
// zone-local inspection path (required for zonal affinity to be effective).
resource "google_compute_forwarding_rule" "main" {
  for_each               = toset(data.google_compute_zones.available.names)
  name                   = "${local.prefix}panw-lb-rule-${each.key}"
  region                 = var.region
  load_balancing_scheme  = "INTERNAL"
  backend_service        = google_compute_region_backend_service.main.id
  ip_address             = cidrhost(var.subnet_cidr_data, 11 + index(data.google_compute_zones.available.names, each.key))
  all_ports              = false
  ports                  = ["6081"]
  ip_protocol            = "UDP"
  network                = google_compute_network.data.id
  subnetwork             = google_compute_subnetwork.data.id
  is_mirroring_collector = var.mirroring_mode
}

# -------------------------------------------------------------------------------------
#  Create firewall service account, instance template, MIG, and autoscaler.
# -------------------------------------------------------------------------------------

// Retrieve zones within the region.
data "google_compute_zones" "available" {
  region = var.region
}

// Create service account for firewall
resource "google_service_account" "main" {
  account_id = "${local.prefix}panw-sa"
}

// Add roles to service account
resource "google_project_iam_member" "main" {
  for_each = var.roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.main.email}"
}

// Create bootstrap bucket download dynamic content to firewall
module "bootstrap" {
  source          = "PaloAltoNetworks/swfw-modules/google//modules/bootstrap"
  version         = "~> 2.0"
  location        = "US"
  service_account = google_service_account.main.email

  files = {
    "bootstrap_files/init-cfg.txt"                       = "config/init-cfg.txt"
    "bootstrap_files/authcodes"                          = "license/authcodes"
    # "bootstrap_files/panup-all-antivirus-5120-5639"      = "content/panup-all-antivirus-5120-5639"
    # "bootstrap_files/panupv2-all-contents-8952-9326"     = "content/panupv2-all-contents-8952-9326"
    # "bootstrap_files/panupv3-all-wildfire-959874-963830" = "content/panupv3-all-wildfire-959874-963830"
    "bootstrap_files/bootstrap.xml"                      = "config/bootstrap.xml"
  }
}

// Create instance template for the firewall
resource "google_compute_instance_template" "main" {
  name_prefix      = "${local.prefix}panw-template"
  machine_type     = var.machine_type
  min_cpu_platform = "Intel Cascade Lake"
  tags             = ["panw-tutorial"]
  can_ip_forward   = true

  metadata = {
    type                                  = "dhcp-client"
    dhcp-send-client-id                   = "yes"
    dhcp-accept-server-hostname           = "yes"
    dhcp-accept-server-domain             = "yes"
    vm-series-auto-registration-pin-id    = var.csp_pin_id
    vm-series-auto-registration-pin-value = var.csp_pin_value
    authcodes                             = var.csp_authcodes
    dns-primary                           = "169.254.169.254"
    vmseries-bootstrap-gce-storagebucket  = module.bootstrap.bucket_name
    # ssh-keys                             = "${file(local.public_key_path)}"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.mgmt.id
    dynamic "access_config" {
      for_each = var.mgmt_public_ip ? [1] : []
      content {}
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.data.id

  }

  disk {
    source_image = "https://www.googleapis.com/compute/v1/projects/paloaltonetworksgcp-public/global/images/${var.image_name}"
    disk_type    = "pd-ssd"
    auto_delete  = true
    boot         = true
  }

  lifecycle {
    create_before_destroy = true
  }

  service_account {
    email = google_service_account.main.email
    scopes = [
      "https://www.googleapis.com/auth/compute.readonly",
      "https://www.googleapis.com/auth/cloud.useraccounts.readonly",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  depends_on = [
    module.bootstrap,
    google_compute_router_nat.main
  ]
}


// Create regional instance group
resource "google_compute_region_instance_group_manager" "main" {
  name                      = "${local.prefix}panw-mig"
  base_instance_name        = "${local.prefix}panw-firewall"
  distribution_policy_zones = data.google_compute_zones.available.names

  version {
    instance_template = google_compute_instance_template.main.id
  }
}


// Configure autoscaling policy for instance group
resource "google_compute_region_autoscaler" "main" {
  name   = "${local.prefix}panw-autoscaler"
  target = google_compute_region_instance_group_manager.main.id

  autoscaling_policy {
    max_replicas    = var.max_firewalls
    min_replicas    = var.min_firewalls
    cooldown_period = 480
    dynamic "metric" {
      for_each = var.vmseries_metrics
      content {
        name   = metric.key
        type   = "GAUGE"
        target = metric.value.target
      }
    }
  }
}


# -------------------------------------------------------------------------------------
# Create custom monitoring dashboard for VM-Series utilization metrics.
# -------------------------------------------------------------------------------------

resource "google_monitoring_dashboard" "dashboard" {
  count          = (local.create_monitoring_dashboard ? 1 : 0)
  dashboard_json = templatefile("${path.root}/bootstrap_files/dashboard.json.tpl", { dashboard_name = "VM-Series Metrics" })

  lifecycle {
    ignore_changes = [
      dashboard_json
    ]
  }
}

# -------------------------------------------------------------------------------------
# Create NSI Deployment Group and Deployment
#
# One deployment is created per zone (keyed off the per-zone forwarding rules) so that
# each zone has a dedicated inspection path. The deployment group is global and
# aggregates every zonal deployment. The deployment group ID is kept constant
# ("${local.prefix}deployment-group") so the consumer's endpoint group reference does
# not need to change when switching between intercept and mirroring modes.
# -------------------------------------------------------------------------------------

# -------------------------------------------------------------------------------------
#  If mirroring_mode = false, create the intercept deployment group and per-zone
#  intercept deployments.
# -------------------------------------------------------------------------------------

resource "google_network_security_intercept_deployment_group" "main" {
  provider                      = google-beta
  count                         = var.mirroring_mode ? 0 : 1
  intercept_deployment_group_id = "${local.prefix}deployment-group"
  location                      = "global"
  network                       = google_compute_network.data.id
}

resource "google_network_security_intercept_deployment" "main" {
  provider                   = google-beta
  for_each                   = var.mirroring_mode ? {} : google_compute_forwarding_rule.main
  intercept_deployment_id    = "${local.prefix}deployment-${each.key}"
  location                   = each.key
  intercept_deployment_group = google_network_security_intercept_deployment_group.main[0].id
  forwarding_rule            = each.value.id
}

# -------------------------------------------------------------------------------------
#  If mirroring_mode = true, create the mirroring deployment group and per-zone
#  mirroring deployments instead.
# -------------------------------------------------------------------------------------

resource "google_network_security_mirroring_deployment_group" "main" {
  provider                      = google-beta
  count                         = var.mirroring_mode ? 1 : 0
  mirroring_deployment_group_id = "${local.prefix}deployment-group"
  location                      = "global"
  network                       = google_compute_network.data.id
}

resource "google_network_security_mirroring_deployment" "main" {
  provider                   = google-beta
  for_each                   = var.mirroring_mode ? google_compute_forwarding_rule.main : {}
  mirroring_deployment_id    = "${local.prefix}deployment-${each.key}"
  location                   = each.key
  mirroring_deployment_group = google_network_security_mirroring_deployment_group.main[0].id
  forwarding_rule            = each.value.id
}
