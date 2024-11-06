variable "aws_region" {
  description = "The region in which the resources will be deployed"
  type        = string
}

variable "aws_profile" {
  description = "The profile to use for the aws provider"
  type        = string
}

variable "cors_allowed_origin" {
  description = "The allowed origin for the CORS policy"
  type        = set(string)
}

