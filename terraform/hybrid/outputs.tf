# 阶段 5.2：输出（ECS 公网 IP 标记为 sensitive，避免出现在日志与截图里）

output "edge_public_ip" {
  description = "ECS 公网 IP（WireGuard 对端地址）"
  value       = local.edge.public_ip
  sensitive   = true
}

output "edge_private_ip" {
  description = "ECS 在 VPC 内的地址"
  value       = local.edge.private_ip
}

output "vpc_cidr" {
  description = "VPC 网段（ECS 上的 FRR 向本地宣告）"
  value       = local.vpc.cidr_block
}

output "onprem_routes" {
  description = "写入 VPC 路由表的本地网段"
  value       = sort(keys(alicloud_route_entry.onprem))
}
