# 阶段 5.2：混合云网络（阿里云 VPC 侧）
#
# 现有的 VPC 与 ECS 只用 data 只读引用：它们不在 state 里，terraform destroy 删不掉年付 ECS。
# Terraform 只拥有两类资源：
#   1. ECS 所在安全组上的一条入方向规则（放行 WireGuard UDP 端口）
#   2. VPC 系统路由表里的自定义路由（本地实验网 → 下一跳 ECS），让同 VPC 的其他云主机经隧道访问实验网
#
# 用法（Mac，terraform/hybrid）：
#   export TF_VAR_edge_instance_id=i-xxxxxxxx      # 或 read -r TF_VAR_edge_instance_id
#   terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw bucket)"
#   terraform plan && terraform apply

data "alicloud_instances" "edge" {
  ids = [var.edge_instance_id]
}

locals {
  edge = data.alicloud_instances.edge.instances[0]
}

data "alicloud_vpcs" "edge" {
  ids = [local.edge.vpc_id]
}

locals {
  vpc = data.alicloud_vpcs.edge.vpcs[0]
}

resource "alicloud_security_group_rule" "wireguard" {
  security_group_id = local.edge.security_groups[0]
  type              = "ingress"
  ip_protocol       = "udp"
  port_range        = "${var.wireguard_port}/${var.wireguard_port}"
  cidr_ip           = var.wireguard_source_cidr
  nic_type          = "intranet" # VPC 类型安全组只能用 intranet
  policy            = "accept"
  priority          = 1
  description       = "k8s-vmware stage5: WireGuard to frr-router (managed by Terraform)"
}

resource "alicloud_route_entry" "onprem" {
  for_each = toset(var.onprem_cidrs)

  route_table_id        = local.vpc.route_table_id
  destination_cidrblock = each.value
  nexthop_type          = "Instance"
  nexthop_id            = var.edge_instance_id
  name                  = "k8s-vmware-${replace(replace(each.value, ".", "-"), "/", "-")}"
  description           = "k8s-vmware stage5: on-prem lab via WireGuard (managed by Terraform)"
}
