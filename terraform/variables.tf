variable "region" {
  type    = string
  default = "eu-north-1"
}
variable "image_tag" {
  type    = string
  default = "latest"
}
variable "desired_count" {
  type    = number
  default = 1 # lab : 1 tâche par service (prod : 2, une par AZ)
}
