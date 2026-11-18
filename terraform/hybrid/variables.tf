# 阶段 5.2：输入变量。edge_instance_id 等个人环境信息通过环境变量 TF_VAR_* 传入，不进仓库（*.tfvars 已被 .gitignore 排除）

variable "region" {
  description = "阿里云地域"
  type        = string
  default     = "cn-hangzhou"
}

variable "edge_instance_id" {
  description = "充当云上边界路由器的现有 ECS 实例 ID（只读引用，不由 Terraform 创建或销毁）"
  type        = string
}

variable "wireguard_port" {
  description = "WireGuard 监听的 UDP 端口"
  type        = number
  default     = 51820
}

variable "wireguard_source_cidr" {
  description = <<-EOT
    允许连接 WireGuard 端口的来源。家宽公网 IP 会变，默认放开；
    WireGuard 对未认证的报文不做任何应答（端口扫描看起来是关闭的），风险可控。家宽 IP 固定时应收紧为 /32。
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "onprem_cidrs" {
  description = "经 ECS 隧道到达的本地实验网网段，写入 VPC 路由表（下一跳 = ECS）"
  type        = list(string)
  default = [
    "10.10.10.0/24", # vmnet2：节点、路由器
    "10.200.0.0/24", # LoadBalancer 地址池
  ]
}
