variable "region" {}
variable "appname" {}
variable "githubRepository" {}
variable "github_oauth_token" {}
variable "vpc_id" {}
variable "subnets" {
  type    = "list"
  default = ["fake-subnet"]
}
