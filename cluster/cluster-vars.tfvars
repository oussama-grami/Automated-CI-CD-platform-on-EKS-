# =============================================================================
# VARIABLES POUR ÉTAPE 1 - CRÉATION DU CLUSTER EKS
# Fichier: cluster-vars.tfvars
# =============================================================================

# Configuration AWS
aws_region = "eu-west-1"  

# Configuration du cluster
cluster_name = "devops-platform-prod"
vpc_cidr     = "10.0.0.0/16"

# =============================================================================
# INSTRUCTIONS
# =============================================================================
# 
# 1. Modifiez uniquement les valeurs ci-dessus si nécessaire
# 2. Ce fichier contient UNIQUEMENT les variables pour créer le cluster EKS
# 3. Les variables GitLab seront dans le fichier de l'étape 2
# 
# =============================================================================