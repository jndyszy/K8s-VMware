# 阶段 5.2：混合云网络（阿里云 VPC 侧）—— provider 与远程 state
terraform {
  required_version = ">= 1.10"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "2.2.0"
    }
  }

  # 部分配置：bucket 不写死，初始化时传入
  #   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw bucket)"
  backend "oss" {
    region  = "cn-hangzhou"
    prefix  = "hybrid"
    key     = "terraform.tfstate"
    encrypt = true
    acl     = "private"
  }
}

provider "alicloud" {
  region = var.region
}
