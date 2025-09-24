# =============================================================================
# DÉPLOIEMENT COMPLET DES OUTILS DEVOPS SUR EKS - VERSION CORRIGÉE
# Fichier: devops-tools.tf
# =============================================================================

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# =============================================================================
# VARIABLES
# =============================================================================

variable "cluster_name" {
  description = "Nom du cluster EKS"
  type        = string
}

variable "aws_region" {
  description = "Région AWS"
  type        = string
}

variable "gitlab_url" {
  description = "URL GitLab"
  type        = string
}

variable "gitlab_registration_token" {
  description = "Token d'enregistrement GitLab Runner"
  type        = string
  sensitive   = true
}

variable "nexus_admin_password" {
  description = "Mot de passe admin Nexus"
  type        = string
  sensitive   = true
  default     = "admin123"
}

variable "sonarqube_admin_password" {
  description = "Mot de passe admin SonarQube"
  type        = string
  sensitive   = true
  default     = "admin123"
}

variable "argocd_admin_password" {
  description = "Mot de passe admin ArgoCD"
  type        = string
  sensitive   = true
  default     = "admin123"
}

# =============================================================================
# DATA SOURCES
# =============================================================================

data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

# =============================================================================
# PROVIDERS
# =============================================================================

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "aws" {
  region = var.aws_region
}

# =============================================================================
# EBS CSI DRIVER SETUP
# =============================================================================

# Politique IAM pour EBS CSI Driver
resource "aws_iam_policy" "ebs_csi_policy" {
  name        = "${var.cluster_name}-ebs-csi-policy"
  description = "Politique IAM pour EBS CSI Driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateVolume",
          "ec2:DeleteVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus",
          "ec2:DescribeVolumeAttribute",
          "ec2:DescribeVolumesModifications",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
          "ec2:DescribeSnapshots",
          "ec2:DescribeSnapshotAttribute",
          "ec2:ModifySnapshotAttribute",
          "ec2:CreateTags",
          "ec2:DeleteTags",
          "ec2:DescribeTags",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeRegions",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      }
    ]
  })
}

# Rôle IAM pour EBS CSI Controller avec IRSA
resource "aws_iam_role" "ebs_csi_role" {
  name = "${var.cluster_name}-ebs-csi-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attacher la politique au rôle
resource "aws_iam_role_policy_attachment" "ebs_csi_policy_attachment" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = aws_iam_policy.ebs_csi_policy.arn
}

# Service Account pour EBS CSI Controller
resource "kubernetes_service_account" "ebs_csi_controller_sa" {
  metadata {
    name      = "ebs-csi-controller-sa"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.ebs_csi_role.arn
    }
    labels = {
      "app.kubernetes.io/name"      = "aws-ebs-csi-driver"
      "app.kubernetes.io/component" = "csi-driver"
    }
  }
}

# Installation EBS CSI Driver via Helm
resource "helm_release" "ebs_csi_driver" {
  name       = "aws-ebs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart      = "aws-ebs-csi-driver"
  namespace  = "kube-system"
  version    = "2.28.1"
  timeout    = 600

  values = [
    yamlencode({
      controller = {
        serviceAccount = {
          create = false
          name   = "ebs-csi-controller-sa"
        }
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "512Mi"
          }
        }
        replicaCount = 1
      }
      node = {
        resources = {
          requests = {
            cpu    = "10m"
            memory = "40Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "256Mi"
          }
        }
      }
      storageClasses = [
        {
          name = "gp3"
          annotations = {
            "storageclass.kubernetes.io/is-default-class" = "true"
          }
          parameters = {
            type   = "gp3"
            fsType = "ext4"
          }
          allowVolumeExpansion = true
          volumeBindingMode    = "Immediate"
          reclaimPolicy        = "Delete"
        }
      ]
    })
  ]

  depends_on = [kubernetes_service_account.ebs_csi_controller_sa]
}

# Attendre que EBS CSI soit prêt
resource "time_sleep" "wait_for_ebs_csi" {
  depends_on = [helm_release.ebs_csi_driver]
  create_duration = "120s"
}

# =============================================================================
# NAMESPACES
# =============================================================================

resource "kubernetes_namespace" "nexus" {
  metadata {
    name = "nexus"
    labels = {
      name = "nexus"
    }
  }
}

resource "kubernetes_namespace" "sonarqube" {
  metadata {
    name = "sonarqube"
    labels = {
      name = "sonarqube"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name = "argocd"
    }
  }
}

resource "kubernetes_namespace" "devops" {
  metadata {
    name = "devops"
    labels = {
      name = "devops"
    }
  }
}

# =============================================================================
# NEXUS REPOSITORY
# =============================================================================

# PVC pour Nexus
resource "kubernetes_persistent_volume_claim" "nexus_storage" {
  metadata {
    name      = "nexus-storage"
    namespace = kubernetes_namespace.nexus.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "30Gi"
      }
    }
    storage_class_name = "gp3"
  }
  
  timeouts {
    create = "10m"
  }
  
  depends_on = [
    kubernetes_namespace.nexus,
    time_sleep.wait_for_ebs_csi
  ]
}

# Deployment Nexus
resource "kubernetes_deployment" "nexus" {
  metadata {
    name      = "nexus"
    namespace = kubernetes_namespace.nexus.metadata[0].name
    labels = {
      app = "nexus"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "nexus"
      }
    }
    template {
      metadata {
        labels = {
          app = "nexus"
        }
      }
      spec {
        security_context {
          fs_group = 200
        }
        init_container {
          name  = "nexus-init"
          image = "busybox:1.35"
          command = [
            "sh", "-c",
            "chown -R 200:200 /nexus-data && chmod -R 755 /nexus-data"
          ]
          volume_mount {
            name       = "nexus-data"
            mount_path = "/nexus-data"
          }
          security_context {
            run_as_user = 0
          }
        }
        container {
          image = "sonatype/nexus3:latest"
          name  = "nexus"
          port {
            container_port = 8081
            name           = "http"
          }
           port {
            container_port = 5000
            name           = "docker"
          }
          env {
            name  = "NEXUS_SECURITY_RANDOMPASSWORD"
            value = "false"
          }
          env {
            name  = "NEXUS_CONTEXT"
            value = "/"
          }
          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }
          volume_mount {
            name       = "nexus-data"
            mount_path = "/nexus-data"
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8081
            }
            initial_delay_seconds = 240
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 6
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8081
            }
            initial_delay_seconds = 180
            period_seconds        = 30
            timeout_seconds       = 10
          }
        }
        volume {
          name = "nexus-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.nexus_storage.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [kubernetes_persistent_volume_claim.nexus_storage]
}

# Service Nexus
resource "kubernetes_service" "nexus" {
  metadata {
    name      = "nexus-service"
    namespace = kubernetes_namespace.nexus.metadata[0].name
    labels = {
      app = "nexus"
    }
  }
  spec {
    selector = {
      app = "nexus"
    }
    port {
      name        = "http"
      port        = 8081
      target_port = 8081
      protocol    = "TCP"
    }
    port {
      name        = "docker"
      port        = 5000
      target_port = 5000
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Secret pour le mot de passe admin Nexus
resource "kubernetes_secret" "nexus_admin" {
  metadata {
    name      = "nexus-admin-secret"
    namespace = kubernetes_namespace.nexus.metadata[0].name
  }
  data = {
    username = base64encode("admin")
    password = base64encode(var.nexus_admin_password)
  }
}

# =============================================================================
# SONARQUBE
# =============================================================================

# PVC pour SonarQube
resource "kubernetes_persistent_volume_claim" "sonarqube_storage" {
  metadata {
    name      = "sonarqube-storage"
    namespace = kubernetes_namespace.sonarqube.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "20Gi"
      }
    }
    storage_class_name = "gp3"
  }
  
  timeouts {
    create = "10m"
  }
  
  depends_on = [
    kubernetes_namespace.sonarqube,
    time_sleep.wait_for_ebs_csi
  ]
}

# Installation SonarQube via Helm
resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube"
  namespace  = kubernetes_namespace.sonarqube.metadata[0].name
  timeout    = 900
  set {
  name  = "monitoringPasscode"
  value = var.sonarqube_admin_password
    }

  values = [
    yamlencode({
      community = {
        enabled = true
      }
      persistence = {
        enabled       = true
        existingClaim = kubernetes_persistent_volume_claim.sonarqube_storage.metadata[0].name
      }
      account = {
        adminPassword = var.sonarqube_admin_password
      }
      postgresql = {
        enabled            = true
        postgresqlPassword = "sonar123"
        persistence = {
          enabled      = true
          size         = "8Gi"
          storageClass = "gp3"
        }
        resources = {
          requests = {
            memory = "256Mi"
            cpu    = "250m"
          }
          limits = {
            memory = "512Mi"
            cpu    = "500m"
          }
        }
      }
      resources = {
        requests = {
          memory = "2Gi"
          cpu    = "500m"
        }
        limits = {
          memory = "4Gi"
          cpu    = "2000m"
        }
      }
      service = {
        type = "ClusterIP"
        port = 9000
      }
      readinessProbe = {
        initialDelaySeconds = 180
        periodSeconds       = 30
        timeoutSeconds      = 10
        failureThreshold    = 6
      }
      livenessProbe = {
        initialDelaySeconds = 240
        periodSeconds       = 30
        timeoutSeconds      = 10
        failureThreshold    = 6
      }
    })
  ]

  depends_on = [kubernetes_persistent_volume_claim.sonarqube_storage]
}

# =============================================================================
# ARGOCD
# =============================================================================

# Installation ArgoCD via Helm
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "5.51.6"
  timeout    = 600

  values = [
    yamlencode({
      configs = {
        secret = {
          argocdServerAdminPassword = bcrypt(var.argocd_admin_password)
        }
        params = {
          "server.insecure" = true
        }
      }
      server = {
        service = {
          type = "ClusterIP"
          port = 80
        }
        extraArgs = ["--insecure"]
        resources = {
          requests = {
            cpu    = "250m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      controller = {
        resources = {
          requests = {
            cpu    = "250m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "1Gi"
          }
        }
      }
      dex = {
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "50m"
            memory = "64Mi"
          }
        }
      }
      redis = {
        resources = {
          requests = {
            cpu    = "10m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "50m"
            memory = "64Mi"
          }
        }
      }
      repoServer = {
        resources = {
          requests = {
            cpu    = "10m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "50m"
            memory = "128Mi"
          }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.argocd]
}

# =============================================================================
# GITLAB RUNNER
# =============================================================================

# Service Account pour GitLab Runner
resource "kubernetes_service_account" "gitlab_runner" {
  metadata {
    name      = "gitlab-runner"
    namespace = kubernetes_namespace.devops.metadata[0].name
  }
}

# ClusterRole pour GitLab Runner
resource "kubernetes_cluster_role" "gitlab_runner" {
  metadata {
    name = "gitlab-runner"
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/exec", "pods/attach", "pods/log"]
    verbs      = ["get", "list", "watch", "create", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets"]
    verbs      = ["get", "list", "watch", "create", "patch", "delete"]
  }
}

# ClusterRoleBinding pour GitLab Runner
resource "kubernetes_cluster_role_binding" "gitlab_runner" {
  metadata {
    name = "gitlab-runner"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.gitlab_runner.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.gitlab_runner.metadata[0].name
    namespace = kubernetes_namespace.devops.metadata[0].name
  }
}

# Secret pour GitLab Runner
resource "kubernetes_secret" "gitlab_runner_secret" {
  metadata {
    name      = "gitlab-runner-secret"
    namespace = kubernetes_namespace.devops.metadata[0].name
  }
  data = {
    registration-token = base64encode(var.gitlab_registration_token)
    gitlab-url        = base64encode(var.gitlab_url)
  }
}

# ConfigMap pour GitLab Runner
resource "kubernetes_config_map" "gitlab_runner_config" {
  metadata {
    name      = "gitlab-runner-config"
    namespace = kubernetes_namespace.devops.metadata[0].name
  }
  data = {
    "config.toml" = <<EOF
concurrent = 4
check_interval = 30

[session_server]
  session_timeout = 1800

[[runners]]
  name = "kubernetes-runner"
  url = "${var.gitlab_url}"
  token = "__REPLACED_BY_REGISTRATION__"
  executor = "kubernetes"
  [runners.kubernetes]
    host = ""
    namespace = "${kubernetes_namespace.devops.metadata[0].name}"
    privileged = true
    image = "ubuntu:20.04"
    cpu_limit = "1000m"
    memory_limit = "2Gi"
    cpu_request = "100m"
    memory_request = "128Mi"
    service_cpu_limit = "200m"
    service_memory_limit = "256Mi"
    helper_cpu_limit = "200m"
    helper_memory_limit = "256Mi"
    poll_timeout = 180
    [runners.kubernetes.pod_labels]
      "gitlab-runner" = "true"
    [[runners.kubernetes.volumes.host_path]]
      name = "docker-sock"
      mount_path = "/var/run/docker.sock"
      read_only = false
      host_path = "/var/run/docker.sock"
EOF
  }
}

# Deployment GitLab Runner
resource "kubernetes_deployment" "gitlab_runner" {
  metadata {
    name      = "gitlab-runner"
    namespace = kubernetes_namespace.devops.metadata[0].name
    labels = {
      app = "gitlab-runner"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "gitlab-runner"
      }
    }
    template {
      metadata {
        labels = {
          app = "gitlab-runner"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.gitlab_runner.metadata[0].name
        container {
          image = "gitlab/gitlab-runner:v16.6.1"
          name  = "gitlab-runner"
          env {
            name = "REGISTRATION_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gitlab_runner_secret.metadata[0].name
                key  = "registration-token"
              }
            }
          }
          env {
            name = "GITLAB_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.gitlab_runner_secret.metadata[0].name
                key  = "gitlab-url"
              }
            }
          }
          env {
            name  = "RUNNER_EXECUTOR"
            value = "kubernetes"
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/gitlab-runner"
            read_only  = true
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.gitlab_runner_config.metadata[0].name
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_secret.gitlab_runner_secret,
    kubernetes_config_map.gitlab_runner_config,
    kubernetes_service_account.gitlab_runner,
    kubernetes_cluster_role_binding.gitlab_runner
  ]
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "deployment_info" {
  description = "Informations de déploiement"
  value = {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
    namespaces = {
      nexus     = kubernetes_namespace.nexus.metadata[0].name
      sonarqube = kubernetes_namespace.sonarqube.metadata[0].name
      argocd    = kubernetes_namespace.argocd.metadata[0].name
      devops    = kubernetes_namespace.devops.metadata[0].name
    }
    services = {
      nexus_service     = "${kubernetes_service.nexus.metadata[0].name}.${kubernetes_service.nexus.metadata[0].namespace}.svc.cluster.local:8081"
      sonarqube_service = "sonarqube-sonarqube.${kubernetes_namespace.sonarqube.metadata[0].name}.svc.cluster.local:9000"
      argocd_service    = "argocd-server.${kubernetes_namespace.argocd.metadata[0].name}.svc.cluster.local:80"
    }
  }
}

output "port_forward_commands" {
  description = "Commandes de port forwarding"
  value = {
    nexus     = "kubectl port-forward svc/nexus-service 8081:8081 -n ${kubernetes_namespace.nexus.metadata[0].name}"
    sonarqube = "kubectl port-forward svc/sonarqube-sonarqube 9000:9000 -n ${kubernetes_namespace.sonarqube.metadata[0].name}"
    argocd    = "kubectl port-forward svc/argocd-server 8080:80 -n ${kubernetes_namespace.argocd.metadata[0].name}"
  }
}

output "admin_credentials" {
  description = "Identifiants administrateur"
  value = {
    nexus = {
      username = "admin"
      password = var.nexus_admin_password
      url      = "http://localhost:8081"
    }
    sonarqube = {
      username = "admin"
      password = var.sonarqube_admin_password
      url      = "http://localhost:9000"
    }
    argocd = {
      username = "admin"
      password = var.argocd_admin_password
      url      = "http://localhost:8080"
    }
  }
  sensitive = true
}