# Data
data azurerm_client_config main {
}

resource random_integer main {
  min = 0
  max = 999
}

resource tls_private_key main {
  algorithm = "RSA"
}

resource local_file main_ssh_public {
  filename          = ".terraform/.ssh/id_rsa.pub"
  sensitive_content = tls_private_key.main.public_key_openssh
}

resource local_file main_ssh_private {
  filename          = ".terraform/.ssh/id_rsa"
  sensitive_content = tls_private_key.main.private_key_pem
  file_permission   = "0500"
}

# Resources
## Azure Kubernetes
### Azure AD Service Principal for Kubernetes
resource azuread_application main {
  name                       = "${var.resource_prefix}-aks Kubernetes"
  available_to_other_tenants = false
  oauth2_allow_implicit_flow = false
  homepage                   = "https://${var.resource_prefix}-aks"
}

resource azuread_service_principal main {
  application_id = azuread_application.main.application_id

  provisioner local-exec {
    command = "sleep 45"
  }
}

resource random_password main_secret {
  length = 40
}

resource azuread_service_principal_password main {
  service_principal_id = azuread_service_principal.main.id
  value                = random_password.main_secret.result
  end_date_relative    = var.service_policy_password_expiry

  provisioner local-exec {
    command = "sleep 45"
  }
}

## Resource Group
resource azurerm_resource_group main {
  name     = "${var.resource_prefix}-aks-rg"
  location = var.location
  tags     = var.tags
}


resource azuread_group main_contributors {
  name = "${azurerm_resource_group.main.name} Contributors"
  members = [
    azuread_service_principal.main.id
  ]
}

resource azurerm_role_assignment main_contributors {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azuread_group.main_contributors.id
}

## Storage
resource azurerm_container_registry main {
  count = var.enable_acr ? 1 : 0
  name = replace(
    "${var.resource_prefix}acr${random_integer.main.result}",
    "-",
    "",
  )
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  sku           = var.acr_sku
  admin_enabled = false
}

resource azuread_group main_acr_pull {
  count = var.enable_acr ? 1 : 0
  name  = "${azurerm_container_registry.main[count.index].name} AcrPull Accessors"
  members = [
    azuread_service_principal.main.id
  ]
}

resource azurerm_role_assignment main_acr_pull {
  count                = var.enable_acr ? 1 : 0
  scope                = azurerm_container_registry.main[count.index].id
  role_definition_name = "AcrPull"
  principal_id         = azuread_group.main_acr_pull[count.index].id
}

## Kubernetes Compute (Azure-level)
resource azurerm_kubernetes_cluster main {
  name                = "${var.resource_prefix}-aks"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags

  service_principal {
    client_id     = azuread_service_principal.main.application_id
    client_secret = azuread_service_principal_password.main.value
  }

  kubernetes_version = var.aks_cluster_kubernetes_version != "" ? var.aks_cluster_kubernetes_version : null

  dns_prefix          = "${var.resource_prefix}-aks"
  node_resource_group = "${var.resource_prefix}-aks-node-rg"

  role_based_access_control {
    enabled = true
  }

  network_profile {
    network_plugin     = "kubenet"
    network_policy     = null
    load_balancer_sku  = "Basic"
    docker_bridge_cidr = "172.17.0.1/16"
    pod_cidr           = "10.244.0.0/16"
    service_cidr       = "10.0.0.0/16"
    dns_service_ip     = "10.0.0.10"
  }

  linux_profile {
    admin_username = "vmadmin"
    ssh_key {
      key_data = tls_private_key.main.public_key_openssh
    }
  }

  agent_pool_profile {
    name            = "nodepool1"
    type            = "AvailabilitySet"
    os_type         = "Linux"
    count           = var.aks_cluster_worker_min_count
    vm_size         = var.aks_cluster_worker_size
    os_disk_size_gb = var.aks_cluster_worker_disk_size
    max_pods        = 100
  }

  addon_profile {
    kube_dashboard {
      enabled = true
    }
  }

  lifecycle {
    ignore_changes = [
      agent_pool_profile[0].count,
      kubernetes_version
    ]
  }
}

resource local_file main_config {
  filename          = ".terraform/.kube/clusters/${azurerm_kubernetes_cluster.main.name}"
  sensitive_content = azurerm_kubernetes_cluster.main.kube_config_raw
  file_permission   = "0500"
}

## Kubernetes Compute Environment (Kubernetes-level) - Helm
### Helm setup
resource kubernetes_service_account main_helm_tiller {
  metadata {
    name      = "tiller"
    namespace = "kube-system"
  }
}

resource kubernetes_cluster_role_binding main_helm_tiller {
  metadata {
    name = "tiller"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.main_helm_tiller.metadata[0].name
    namespace = kubernetes_service_account.main_helm_tiller.metadata[0].namespace
  }
}

data helm_repository stable {
  name = "stable"
  url  = "https://kubernetes-charts.storage.googleapis.com"
}

data helm_repository jetstack {
  name = "jetstack"
  url  = "https://charts.jetstack.io"
}

### Cluster Utilities
resource helm_release main_autoscaler {
  name = "cluster-autoscaler"

  repository = data.helm_repository.stable.metadata[0].name
  chart      = "cluster-autoscaler"
  version    = var.aks_cluster_cluster_autoscaler_chart_version
  namespace  = "kube-system"

  values = [
    templatefile(
      "${path.module}/templates/kubernetes/helm/values/cluster-autoscaler.yaml.tpl",
      {
        azureTenantID          = data.azurerm_client_config.main.tenant_id
        azureSubscriptionID    = data.azurerm_client_config.main.subscription_id
        azureResourceGroup     = azurerm_resource_group.main.name
        azureClusterName       = azurerm_kubernetes_cluster.main.name
        azureNodeResourceGroup = azurerm_kubernetes_cluster.main.node_resource_group
        azureClientID          = azuread_application.main.application_id
        azureClientSecret      = azuread_service_principal_password.main.value
        nodeGroupMaxSize       = var.aks_cluster_worker_max_count
        nodeGroupMinSize       = var.aks_cluster_worker_min_count
        nodeGroupName          = azurerm_kubernetes_cluster.main.agent_pool_profile[0].name
      }
    )
  ]

  depends_on = [kubernetes_cluster_role_binding.main_helm_tiller]
}

resource helm_release main_ingress {
  name = "nginx-ingress"

  repository = data.helm_repository.stable.metadata[0].name
  chart      = "nginx-ingress"
  version    = var.aks_cluster_nginx_ingress_chart_version
  namespace  = "kube-system"

  values = [
    templatefile(
      "${path.module}/templates/kubernetes/helm/values/nginx-ingress.yaml.tpl",
      {
        customBackendService = var.aks_cluster_custom_backend_service
      }
    )
  ]

  timeout = 600

  depends_on = [kubernetes_cluster_role_binding.main_helm_tiller]
}

resource helm_release main_cert_manager {
  name = "cert-manager"

  repository = data.helm_repository.jetstack.metadata[0].name
  chart      = "cert-manager"
  version    = var.aks_cluster_cert_manager_chart_version
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/templates/kubernetes/helm/values/cert-manager.yaml.tpl", {})
  ]

  provisioner local-exec {
    command = <<EOS
kubectl apply --kubeconfig .terraform/.kube/clusters/${azurerm_kubernetes_cluster.main.name} -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.9/deploy/manifests/00-crds.yaml
EOS
  }

  timeout = 600

  depends_on = [kubernetes_cluster_role_binding.main_helm_tiller]
}

## Kubernetes Compute Environment (Kubernetes-level) - Storage
resource kubernetes_storage_class main_azure {
  // Default storage classes do not expand. Create these in the cluster as part of the deployment.
  for_each = {
    "azure-standard" = "Standard_LRS"
    "azure-premium"  = "Premium_LRS"
  }

  metadata {
    name = each.key

    labels = {
      "kubernetes.io/cluster-service" = "true"
    }
  }

  storage_provisioner    = "kubernetes.io/azure-disk"
  allow_volume_expansion = "true"
  reclaim_policy         = "Delete"

  parameters = {
    kind               = "managed"
    storageaccounttype = each.value
  }
}

## Kubernetes Service Accounts
### Full Access
resource kubernetes_service_account main_full_access {
  metadata {
    name      = "cluster-full-access"
    namespace = "kube-system"
  }
}

resource kubernetes_cluster_role_binding main_full_access {
  metadata {
    name = "cluster-full-access"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.main_full_access.metadata[0].name
    namespace = kubernetes_service_account.main_full_access.metadata[0].namespace
  }
}

### Read Only
resource kubernetes_service_account main_read_only {
  metadata {
    name      = "cluster-read-only"
    namespace = "kube-system"
  }
}

resource kubernetes_cluster_role_binding main_read_only {
  metadata {
    name = "cluster-read-only"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.main_read_only.metadata[0].name
    namespace = kubernetes_service_account.main_read_only.metadata[0].namespace
  }
}

### Dashboard
resource kubernetes_cluster_role_binding main_dashboard_view {
  metadata {
    name = "kubernetes-dashboard"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kubernetes-dashboard"
    namespace = "kube-system"
  }
}
