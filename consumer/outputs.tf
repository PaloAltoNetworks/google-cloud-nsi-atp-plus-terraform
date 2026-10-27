
output "SET_ENV_VARS" {
  value = <<EOF

export CONSUMER_PROJECT=${var.project_id}
export CONSUMER_VPC=${google_compute_network.main.name}
export REGION=${var.region}
export ZONE=${google_compute_instance.client.zone}
export CLIENT_VM=${google_compute_instance.client.name}
export CLUSTER=${length(data.google_container_cluster.main) > 0 ? data.google_container_cluster.main[0].name : ""}

EOF
}