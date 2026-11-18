# 阶段 5.1：Terraform 远程 state 的 OSS 桶（先有鸡还是先有蛋：这个模块自己的 state 只能放本地）
#
# 用法（Mac，仓库根目录下 terraform/bootstrap）：
#   terraform init && terraform apply
#   terraform output -raw bucket     # 供 terraform/hybrid 初始化 backend 使用
# 本模块的 terraform.tfstate 留在本地且被 .gitignore 排除；丢失只意味着桶脱离管理，桶和里面的 state 不受影响。

terraform {
  required_version = ">= 1.10"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "2.2.0"
    }
  }
}

# 凭据从环境变量 ALICLOUD_ACCESS_KEY / ALICLOUD_SECRET_KEY 读取，不写进任何文件
provider "alicloud" {
  region = var.region
}

variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

# 桶名全局唯一：用账号 ID 做后缀，确定且不需要随机数 provider
data "alicloud_account" "current" {}

locals {
  bucket = "k8s-vmware-tfstate-${data.alicloud_account.current.id}"
}

resource "alicloud_oss_bucket" "tfstate" {
  bucket        = local.bucket
  storage_class = "Standard"

  lifecycle {
    # state 桶误删代价极高
    prevent_destroy = true
    # 下面三项由独立资源管理，按 provider 文档要求在桶资源上忽略，避免两边争夺同一配置
    ignore_changes = [acl, versioning, server_side_encryption_rule]
  }
}

resource "alicloud_oss_bucket_acl" "tfstate" {
  bucket = alicloud_oss_bucket.tfstate.bucket
  acl    = "private"
}

resource "alicloud_oss_bucket_public_access_block" "tfstate" {
  bucket              = alicloud_oss_bucket.tfstate.bucket
  block_public_access = true
}

# 版本控制：state 被写坏或误删时可以回滚到上一个版本
resource "alicloud_oss_bucket_versioning" "tfstate" {
  bucket = alicloud_oss_bucket.tfstate.bucket
  status = "Enabled"
}

resource "alicloud_oss_bucket_server_side_encryption" "tfstate" {
  bucket        = alicloud_oss_bucket.tfstate.bucket
  sse_algorithm = "AES256"
}

output "bucket" {
  description = "state 桶名，terraform/hybrid 初始化时通过 -backend-config 传入"
  value       = alicloud_oss_bucket.tfstate.bucket
}
