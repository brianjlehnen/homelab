# Manually Managed Services

## AdGuard Home
- **Location**: network namespace
- **Management**: Manual kubectl (not ArgoCD)
- **Reason**: Critical DNS infrastructure - stability over automation
- **Services**: adguard-home-dns (LoadBalancer), adguard-home-web (ClusterIP)

