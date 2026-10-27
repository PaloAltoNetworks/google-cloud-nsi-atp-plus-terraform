variable "project_id" {
  description = "The deployment project ID."
  type        = string
}

variable "region" {
  description = "The region for the deployment."
  default     = "us-west1"
  type        = string
}

variable "mgmt_allow_ips" {
  description = "A list of IP addresses to be added to the consumer network's ingress firewall rule. The IP addresses will be able to access to the workloads in the consumer network."
  type        = list(string)
}

variable "prefix" {
  description = "A unique string to prepend to each created resource."
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "The IPv4 subnet CIDR for the consumer subnetwork."
  default     = "10.1.0.0/24"
  type        = string
}

variable "create_gke" {
  description = "Whether to create the GKE cluster."
  type        = bool
  default     = true
}

variable "producer_project_id" {
  description = "Project ID of the producer environment."
  type        = string
  default     = ""
}

variable "deployment_group_id" {
  description = "Deployment Group ID from the producer project."
  type        = string
  default     = "deployment-group"
}
