variable "project" {
  description = "Project name, used as a prefix for all resources."
  type        = string
  default     = "ecs-api"
}

variable "environment" {
  description = "Environment name (dev, staging, ...)."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread across."
  type        = number
  default     = 2
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "cpu" {
  description = "Fargate task CPU units (256, 512, 1024, ...)."
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MiB (must be a valid pair with cpu)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Initial task count (autoscaling takes over afterwards)."
  type        = number
  default     = 1
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 4
}

variable "image_tag" {
  description = "Image tag in ECR to deploy. CI passes the git SHA."
  type        = string
  default     = "bootstrap"
}

variable "log_retention_days" {
  type    = number
  default = 14
}
