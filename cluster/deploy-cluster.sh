#!/bin/bash

# =============================================================================
# SCRIPT DE DÉPLOIEMENT ÉTAPE 1 - CLUSTER EKS
# Fichier: deploy-cluster.sh
# =============================================================================

set -e

# Configuration des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Fonction pour vérifier les prérequis
check_prerequisites() {
    log_info "Vérification des prérequis..."
    
    # Vérifier AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI n'est pas installé. Veuillez l'installer d'abord."
        exit 1
    fi
    
    # Vérifier OpenTofu
    if ! command -v tofu &> /dev/null; then
        log_error "OpenTofu n'est pas installé. Veuillez l'installer d'abord."
        exit 1
    fi
    
    # Vérifier kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl n'est pas installé. Veuillez l'installer d'abord."
        exit 1
    fi
    
    # Vérifier les credentials AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "Credentials AWS non configurés. Exécutez 'aws configure' d'abord."
        exit 1
    fi
    
    # Vérifier si cluster-vars.tfvars existe
    if [ ! -f "cluster-vars.tfvars" ]; then
        log_error "Le fichier cluster-vars.tfvars n'existe pas. Veuillez le créer avec vos configurations."
        exit 1
    fi
    
    # Vérifier si cluster.tf existe
    if [ ! -f "cluster.tf" ]; then
        log_error "Le fichier cluster.tf n'existe pas. Veuillez le créer."
        exit 1
    fi
    
    log_success "Tous les prérequis sont satisfaits."
}

# Fonction pour initialiser Terraform
init_terraform() {
    log_info "Initialisation d'OpenTofu pour l'infrastructure EKS..."
    tofu init
    log_success "OpenTofu initialisé avec succès."
}

# Fonction pour planifier le déploiement
plan_deployment() {
    log_info "Planification du déploiement du cluster EKS..."
    tofu plan -var-file="cluster-vars.tfvars" -out=cluster-plan
    log_success "Plan du cluster généré avec succès."
}

# Fonction pour appliquer le déploiement
apply_deployment() {
    log_info "Création du cluster EKS (ceci prendra 10-15 minutes)..."
    tofu apply cluster-plan
    log_success "Cluster EKS créé avec succès."
}

# Fonction pour configurer kubectl
configure_kubectl() {
    log_info "Configuration de kubectl..."
    
    # Récupérer les informations du cluster
    CLUSTER_NAME=$(tofu output -raw cluster_name)
    AWS_REGION=$(tofu output -raw aws_region)
    
    # Configurer kubectl
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
    
    log_success "kubectl configuré avec succès."
    
    # Tester la connexion
    log_info "Test de la connexion au cluster..."
    if kubectl get nodes &> /dev/null; then
        log_success "Connexion au cluster réussie."
        kubectl get nodes
    else
        log_warning "Connexion au cluster échouée. Le cluster est peut-être encore en cours d'initialisation."
    fi
}

# Fonction pour vérifier l'état du cluster
check_cluster_status() {
    log_info "Vérification de l'état du cluster..."
    
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if kubectl get nodes 2>/dev/null | grep -q "Ready"; then
            log_success "Le cluster est opérationnel!"
            kubectl get nodes
            return 0
        fi
        
        log_info "Tentative $attempt/$max_attempts - Cluster pas encore complètement prêt..."
        sleep 30
        ((attempt++))
    done
    
    log_warning "Le cluster prend plus de temps que prévu à devenir opérationnel."
    log_info "Continuez avec l'étape 2 dans quelques minutes."
    return 1
}

# Fonction pour afficher les informations du cluster
display_cluster_info() {
    log_info "Récupération des informations du cluster..."
    
    echo ""
    echo "=============================================="
    echo "    CLUSTER EKS CRÉÉ AVEC SUCCÈS"
    echo "=============================================="
    
    # Récupérer les informations
    CLUSTER_NAME=$(tofu output -raw cluster_name)
    AWS_REGION=$(tofu output -raw aws_region)
    CLUSTER_ENDPOINT=$(tofu output -raw cluster_endpoint)
    VPC_ID=$(tofu output -raw vpc_id)
    
    echo "📍 INFORMATIONS DU CLUSTER:"
    echo "   Nom: $CLUSTER_NAME"
    echo "   Région: $AWS_REGION"
    echo "   Endpoint: $CLUSTER_ENDPOINT"
    echo "   VPC ID: $VPC_ID"
    echo ""
    
    echo "📋 COMMANDES UTILES:"
    echo "   kubectl get nodes"
    echo "   kubectl get pods --all-namespaces"
    echo "   kubectl get svc --all-namespaces"
    echo ""
    
    echo "🎯 PROCHAINE ÉTAPE:"
    echo "   ./deploy-devops-tools.sh"
    echo ""
    
    # Sauvegarder les informations
    cat > cluster-info.txt << EOF
=== INFORMATIONS DU CLUSTER EKS ===
Date de création: $(date)
Nom du cluster: $CLUSTER_NAME
Région AWS: $AWS_REGION
Endpoint: $CLUSTER_ENDPOINT
VPC ID: $VPC_ID

Configuration kubectl:
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

Commandes de vérification:
kubectl get nodes
kubectl get pods --all-namespaces

Prochaine étape:
./deploy-devops-tools.sh
EOF
    
    log_success "Informations sauvegardées dans 'cluster-info.txt'"
}

# Fonction pour nettoyer en cas d'échec
cleanup_on_failure() {
    log_warning "Nettoyage en cours suite à un échec..."
    tofu destroy -var-file="cluster-vars.tfvars" -auto-approve
    log_info "Nettoyage terminé."
}

# Fonction principale
main() {
    echo "=============================================="
    echo "  ÉTAPE 1: CRÉATION DU CLUSTER EKS"
    echo "=============================================="
    echo ""
    
    # Vérifier les prérequis
    check_prerequisites
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous créer le cluster EKS? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Création du cluster annulée par l'utilisateur."
        exit 0
    fi
    
    # Piège pour nettoyer en cas d'erreur
    trap cleanup_on_failure ERR
    
    # Étapes du déploiement
    init_terraform
    plan_deployment
    apply_deployment
    configure_kubectl
    check_cluster_status
    display_cluster_info
    
    echo ""
    log_success "🎉 CLUSTER EKS CRÉÉ AVEC SUCCÈS! 🎉"
    echo ""
    echo "Le cluster est maintenant prêt pour l'installation des outils DevOps."
    echo "Passez à l'étape 2: ./deploy-devops-tools.sh"
    echo ""
}

# Fonction pour détruire le cluster
destroy() {
    echo "=============================================="
    echo "  DESTRUCTION DU CLUSTER EKS"
    echo "=============================================="
    echo ""
    
    log_warning "ATTENTION: Cette action va détruire complètement le cluster EKS!"
    echo ""
    read -p "Êtes-vous sûr de vouloir continuer? Tapez 'DESTROY' pour confirmer: " -r
    echo
    if [[ $REPLY != "DESTROY" ]]; then
        log_info "Destruction annulée."
        exit 0
    fi
    
    log_info "Destruction du cluster EKS en cours..."
    tofu destroy -var-file="cluster-vars.tfvars" -auto-approve
    log_success "Cluster EKS détruit avec succès."
}

# Gestion des arguments
case "${1:-}" in
    "destroy")
        destroy
        ;;
    "")
        main
        ;;
    *)
        echo "Usage: $0 [destroy]"
        echo "  Sans argument: Crée le cluster EKS"
        echo "  destroy: Détruit le cluster EKS"
        exit 1
        ;;
esac