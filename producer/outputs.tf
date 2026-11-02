output "ENVIRONMENT_VARIABLES" {
  value = <<EOT

export PRODUCER_PROJECT=${var.project_id}
export DATA_VPC=${google_compute_network.data.name}
export DATA_SUBNET=${google_compute_subnetwork.data.name}
export REGION=${var.region}
export ZONE=${data.google_compute_zones.available.names[0]}
export BACKEND_SERVICE=${google_compute_region_backend_service.main.self_link}
export DEPLOYMENT_GROUP=${var.mirroring_mode ? google_network_security_mirroring_deployment_group.main[0].id : google_network_security_intercept_deployment_group.main[0].id}

export TF_VAR_producer_project_id="$PRODUCER_PROJECT"
export TF_VAR_deployment_group="$DEPLOYMENT_GROUP"
export TF_VAR_region="$REGION"
EOT

}
