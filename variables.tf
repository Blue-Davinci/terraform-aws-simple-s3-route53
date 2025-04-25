variable "region" {
    description = "value of the region to deploy the resources"
    type = string
    default = "us-east-1"
}

variable "domain_name" {
    description = "Domain name for the hosted zone"
    type = string
}
