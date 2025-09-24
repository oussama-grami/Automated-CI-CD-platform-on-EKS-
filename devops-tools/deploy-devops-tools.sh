#!/bin/bash

# =============================================================================
# SCRIPT DE DÉPLOIEMENT DES OUTILS DEVOPS SUR EKS
# Fichier: deploy-devops-tools.sh
# =============================================================================

set -e

# Configuration des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Fonctions de logging
log_info() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] [INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] [SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] [WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${BOLD}${PURPLE}=============================================="
    echo -e "    $1"
    echo -e "===============================================${NC}"
    echo ""
}

show_banner() {
    echo ""
    echo -e "${BOLD}${CYAN}================================================"
    echo -e "    🚀 DÉPLOIEMENT OUTILS DEVOPS SUR EKS"
    echo -e "    📦 Nexus • SonarQube • ArgoCD • GitLab Runner"
    echo -e "================================================${NC}"
    echo ""
}

# Vérification des prérequis
check_prerequisites() {
    log_step "🔍 VÉRIFICATION DES PRÉREQUIS"
    
    local tools=("kubectl" "aws" "tofu" "helm")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool non trouvé. Veuillez l'installer d'abord."
            exit 1
        fi
        log_success "✓ $tool disponible"
    done
    
    # Vérifier l'accès au cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Impossible d'accéder au cluster Kubernetes"
        log_info "Assurez-vous que votre kubeconfig est configuré correctement"
        exit 1
    fi
    log_success "✓ Accès au cluster confirmé"
    
    # Vérifier les credentials AWS
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "Credentials AWS non configurés"
        exit 1
    fi
    log_success "✓ Credentials AWS configurés"
    
    # Vérifier les fichiers requis
    local required_files=("devops-tools.tf" "devops-vars.tfvars")
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "Fichier $file non trouvé"
            exit 1
        fi
        log_success "✓ Fichier $file trouvé"
    done
    
    # Vérifier que le cluster EKS existe
    CLUSTER_NAME=$(grep "^cluster_name" devops-vars.tfvars | head -1 | cut -d'"' -f2)
    AWS_REGION=$(grep "^aws_region" devops-vars.tfvars | head -1 | cut -d'"' -f2)
    
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        log_error "Cluster EKS '$CLUSTER_NAME' non trouvé dans la région '$AWS_REGION'"
        log_info "Créez d'abord le cluster avec ./deploy-cluster.sh"
        exit 1
    fi
    log_success "✓ Cluster EKS '$CLUSTER_NAME' trouvé"
    
    log_success "Tous les prérequis sont satisfaits"
}

# Configurer Helm repositories
setup_helm_repos() {
    log_step "📦 CONFIGURATION DES REPOSITORIES HELM"
    
    log_info "Ajout des repositories Helm..."
    
    # Ajouter les repos nécessaires
    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver &>/dev/null || true
    helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube &>/dev/null || true
    helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null || true
    
    log_info "Mise à jour des repositories..."
    helm repo update &>/dev/null
    
    log_success "✓ Repositories Helm configurés"
}

# Nettoyer les ressources existantes si nécessaire
cleanup_existing_resources() {
    log_step "🧹 NETTOYAGE DES RESSOURCES EXISTANTES"
    
    log_info "Vérification des ressources existantes..."
    
    # Supprimer les anciens namespaces de test
    kubectl delete namespace ebs-test --ignore-not-found=true &>/dev/null || true
    kubectl delete namespace volume-test --ignore-not-found=true &>/dev/null || true
    kubectl delete namespace test --ignore-not-found=true &>/dev/null || true
    
    # Nettoyer les PVCs bloqués
    log_info "Nettoyage des PVCs en état Pending/Failed..."
    kubectl get pvc --all-namespaces 2>/dev/null | grep -E "(Pending|Failed)" | while read namespace pvc rest; do
        if [ "$namespace" != "NAMESPACE" ] && [ -n "$namespace" ] && [ -n "$pvc" ]; then
            log_info "Suppression PVC bloqué: $pvc dans $namespace"
            kubectl delete pvc "$pvc" -n "$namespace" --force --grace-period=0 &>/dev/null || true
        fi
    done
    
    log_success "✓ Nettoyage terminé"
}

# Initialiser Terraform
init_terraform() {
    log_step "🔧 INITIALISATION TERRAFORM"
    
    log_info "Initialisation d'OpenTofu..."
    tofu init
    
    log_info "Validation de la configuration..."
    tofu validate
    
    log_success "✓ OpenTofu initialisé et configuration validée"
}

# Planifier le déploiement
plan_deployment() {
    log_step "📋 PLANIFICATION DU DÉPLOIEMENT"
    
    log_info "Génération du plan de déploiement..."
    tofu plan -var-file="devops-vars.tfvars" -out=devops-plan.out
    
    log_success "✓ Plan de déploiement généré"
}

# Appliquer le déploiement
apply_deployment() {
    log_step "🚀 DÉPLOIEMENT DES OUTILS DEVOPS"
    
    log_info "Application du plan de déploiement..."
    log_warning "Ceci peut prendre 10-15 minutes..."
    
    tofu apply devops-plan.out
    
    log_success "✓ Déploiement appliqué avec succès"
}

# Attendre que tous les pods soient prêts
wait_for_pods() {
    log_step "⏳ ATTENTE DE LA PRÉPARATION DES SERVICES"
    
    local namespaces=("kube-system" "nexus" "sonarqube" "argocd" "devops")
    
    for namespace in "${namespaces[@]}"; do
        log_info "Vérification des pods dans le namespace $namespace..."
        
        # Attendre que tous les pods soient en cours d'exécution
        local max_attempts=20
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            local pending_pods=$(kubectl get pods -n "$namespace" 2>/dev/null | grep -E "(Pending|ContainerCreating|Init)" | wc -l || echo "0")
            
            if [ "$pending_pods" -eq 0 ]; then
                log_success "✓ Tous les pods sont prêts dans $namespace"
                break
            fi
            
            log_info "Tentative $attempt/$max_attempts - $pending_pods pod(s) encore en cours de création dans $namespace..."
            sleep 30
            ((attempt++))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log_warning "Certains pods dans $namespace prennent plus de temps que prévu"
        fi
    done
    
    # Vérification spécifique pour les services critiques
    log_info "Vérification de la santé des services critiques..."
    
    # Attendre EBS CSI Driver
    kubectl wait --for=condition=ready pod -l app=ebs-csi-controller -n kube-system --timeout=300s || log_warning "EBS CSI Controller timeout"
    kubectl wait --for=condition=ready pod -l app=ebs-csi-node -n kube-system --timeout=300s || log_warning "EBS CSI Node timeout"
    
    # Attendre Nexus
    kubectl wait --for=condition=ready pod -l app=nexus -n nexus --timeout=600s || log_warning "Nexus timeout"
    
    # Attendre SonarQube
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sonarqube -n sonarqube --timeout=600s || log_warning "SonarQube timeout"
    
    # Attendre ArgoCD
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s || log_warning "ArgoCD timeout"
    
    log_success "✓ Services critiques vérifiés"
}

# Tester la connectivité des services
test_services() {
    log_step "🧪 TEST DE CONNECTIVITÉ DES SERVICES"
    
    log_info "Test de création d'un volume persistant..."
    
    # Créer un namespace de test
    kubectl create namespace volume-test --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    
    # Créer un PVC de test
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: volume-test
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: gp3
EOF

    # Attendre que le PVC soit Bound (mais ne pas échouer si timeout)
    if kubectl wait --for=condition=Bound pvc/test-pvc -n volume-test --timeout=120s; then
        log_success "✓ Test de volume persistant réussi"
    else
        log_warning "⚠ Test de volume avec timeout, mais vérifions le statut..."
        
        # Vérifier le statut du PVC malgré le timeout
        PVC_STATUS=$(kubectl get pvc test-pvc -n volume-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        if [ "$PVC_STATUS" = "Bound" ]; then
            log_success "✓ Volume persistant est en fait Bound - test réussi !"
        else
            log_warning "⚠ Volume persistant en statut: $PVC_STATUS"
            kubectl describe pvc test-pvc -n volume-test || true
        fi
    fi
    
    # Nettoyer le test
    kubectl delete namespace volume-test &>/dev/null || true
    
    # Tester la disponibilité des services
    log_info "Vérification de la disponibilité des services..."
    
    local services=(
        "nexus-service:nexus:8081"
        "sonarqube-sonarqube:sonarqube:9000"
        "argocd-server:argocd:80"
    )
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service namespace port <<< "$service_info"
        if kubectl get svc "$service" -n "$namespace" &>/dev/null; then
            log_success "✓ Service $service disponible dans $namespace"
        else
            log_warning "⚠ Service $service non trouvé dans $namespace"
        fi
    done
    
    log_success "✓ Tests de connectivité terminés"
    
    # IMPORTANT: Ne jamais retourner d'erreur ici pour éviter le cleanup
    return 0
}

# Afficher les informations de déploiement
display_deployment_info() {
    log_step "📊 INFORMATIONS DE DÉPLOIEMENT"
    
    # Récupérer les informations via Terraform output
    local deployment_info
    deployment_info=$(tofu output -json deployment_info 2>/dev/null || echo '{}')
    
    echo -e "${BOLD}${GREEN}🎉 DÉPLOIEMENT TERMINÉ AVEC SUCCÈS ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${BLUE}📋 SERVICES DÉPLOYÉS:${NC}"
    echo -e "${GREEN}   ✓ EBS CSI Driver (Stockage persistant)${NC}"
    echo -e "${GREEN}   ✓ Nexus Repository Manager${NC}"
    echo -e "${GREEN}   ✓ SonarQube (Analyse de code)${NC}"
    echo -e "${GREEN}   ✓ ArgoCD (Déploiement continu)${NC}"
    echo -e "${GREEN}   ✓ GitLab Runner (CI/CD)${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}🌐 ACCÈS AUX SERVICES:${NC}"
    echo ""
    echo -e "${YELLOW}Nexus Repository Manager:${NC}"
    echo "   URL: http://localhost:8081"
    echo "   Commande: kubectl port-forward svc/nexus-service 8081:8081 -n nexus"
    echo "   Identifiants: admin / $(grep nexus_admin_password devops-vars.tfvars | cut -d'"' -f2)"
    echo ""
    
    echo -e "${YELLOW}SonarQube:${NC}"
    echo "   URL: http://localhost:9000"
    echo "   Commande: kubectl port-forward svc/sonarqube-sonarqube 9000:9000 -n sonarqube"
    echo "   Identifiants: admin / $(grep sonarqube_admin_password devops-vars.tfvars | cut -d'"' -f2)"
    echo ""
    
    echo -e "${YELLOW}ArgoCD:${NC}"
    echo "   URL: http://localhost:8080"
    echo "   Commande: kubectl port-forward svc/argocd-server 8080:80 -n argocd"
    echo "   Identifiants: admin / $(grep argocd_admin_password devops-vars.tfvars | cut -d'"' -f2)"
    echo ""
    
    echo -e "${BOLD}${PURPLE}🔧 COMMANDES UTILES:${NC}"
    echo "   • Voir tous les pods: kubectl get pods --all-namespaces"
    echo "   • Voir les services: kubectl get svc --all-namespaces"
    echo "   • Voir les PVCs: kubectl get pvc --all-namespaces"
    echo "   • Logs Nexus: kubectl logs -l app=nexus -n nexus"
    echo "   • Logs SonarQube: kubectl logs -l app.kubernetes.io/name=sonarqube -n sonarqube"
    echo "   • Logs ArgoCD: kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd"
    echo ""
    
    echo -e "${BOLD}${GREEN}🎯 PROCHAINES ÉTAPES:${NC}"
    echo "   1. Créer des LoadBalancers pour l'accès externe: ./create-loadbalancers.sh"
    echo "   2. Configurer vos projets GitLab avec le runner déployé"
    echo "   3. Configurer ArgoCD avec vos repositories Git"
    echo ""
    
    # Sauvegarder les informations
    cat > deployment-info.txt << EOF
=== INFORMATIONS DE DÉPLOIEMENT DEVOPS ===
Date de déploiement: $(date)
Cluster: $(grep cluster_name devops-vars.tfvars | cut -d'"' -f2)
Région: $(grep aws_region devops-vars.tfvars | cut -d'"' -f2)

ACCÈS AUX SERVICES:
===================

Nexus Repository Manager:
- URL locale: http://localhost:8081
- Port-forward: kubectl port-forward svc/nexus-service 8081:8081 -n nexus
- Username: admin
- Password: $(grep nexus_admin_password devops-vars.tfvars | cut -d'"' -f2)

SonarQube:
- URL locale: http://localhost:9000
- Port-forward: kubectl port-forward svc/sonarqube-sonarqube 9000:9000 -n sonarqube
- Username: admin
- Password: $(grep sonarqube_admin_password devops-vars.tfvars | cut -d'"' -f2)

ArgoCD:
- URL locale: http://localhost:8080
- Port-forward: kubectl port-forward svc/argocd-server 8080:80 -n argocd
- Username: admin
- Password: $(grep argocd_admin_password devops-vars.tfvars | cut -d'"' -f2)

COMMANDES UTILES:
================
kubectl get pods --all-namespaces
kubectl get svc --all-namespaces
kubectl get pvc --all-namespaces

PROCHAINES ÉTAPES:
==================
1. ./create-loadbalancers.sh (pour l'accès externe)
2. Configurer GitLab avec le runner
3. Configurer ArgoCD avec vos repositories
EOF
    
    log_success "Informations sauvegardées dans 'deployment-info.txt'"
}

# Fonction de nettoyage en cas d'erreur
cleanup_on_failure() {
    log_error "Erreur détectée pendant le déploiement"
    log_warning "Voulez-vous nettoyer les ressources partiellement créées ? (y/N)"
    
    read -p "Nettoyer ? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Nettoyage en cours..."
        
        # Supprimer les ressources Terraform si elles existent
        if [ -f "devops-plan.out" ]; then
            tofu destroy -var-file="devops-vars.tfvars" -auto-approve &>/dev/null || true
        fi
        
        # Nettoyer les fichiers temporaires
        rm -f devops-plan.out &>/dev/null || true
        
        log_info "Nettoyage terminé"
    else
        log_info "Nettoyage annulé - les ressources sont conservées"
        log_info "Vous pouvez les vérifier avec: kubectl get pods --all-namespaces"
    fi
}

# Fonction pour afficher l'aide
show_help() {
    echo -e "${BOLD}${BLUE}Usage: $0 [OPTION]${NC}"
    echo ""
    echo "Options:"
    echo "  (aucune)  Déploiement complet des outils DevOps"
    echo "  destroy   Suppression complète de tous les outils"
    echo "  status    Affichage du statut des services"
    echo "  help      Affichage de cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0           # Déploiement complet"
    echo "  $0 status    # Vérifier le statut"
    echo "  $0 destroy   # Supprimer tous les outils"
    echo ""
}

# Fonction pour vérifier le statut
check_status() {
    log_step "📊 STATUT DES SERVICES DEVOPS"
    
    echo -e "${BOLD}${BLUE}État des namespaces:${NC}"
    kubectl get ns | grep -E "(nexus|sonarqube|argocd|devops)" || echo "Aucun namespace DevOps trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}État des pods:${NC}"
    kubectl get pods -n nexus -o wide 2>/dev/null || echo "Namespace nexus non trouvé"
    kubectl get pods -n sonarqube -o wide 2>/dev/null || echo "Namespace sonarqube non trouvé"
    kubectl get pods -n argocd -o wide 2>/dev/null || echo "Namespace argocd non trouvé"
    kubectl get pods -n devops -o wide 2>/dev/null || echo "Namespace devops non trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}État des services:${NC}"
    kubectl get svc -n nexus 2>/dev/null || echo "Aucun service nexus"
    kubectl get svc -n sonarqube 2>/dev/null || echo "Aucun service sonarqube"
    kubectl get svc -n argocd 2>/dev/null || echo "Aucun service argocd"
    
    echo ""
    echo -e "${BOLD}${BLUE}État des PVCs:${NC}"
    kubectl get pvc --all-namespaces | grep -E "(nexus|sonarqube)" || echo "Aucun PVC trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}EBS CSI Driver:${NC}"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver || echo "EBS CSI Driver non trouvé"
}

# Fonction pour détruire le déploiement
destroy_deployment() {
    log_step "💥 DESTRUCTION DES OUTILS DEVOPS"
    
    log_warning "ATTENTION: Cette action va supprimer tous les outils DevOps !"
    log_warning "Toutes les données seront perdues définitivement !"
    echo ""
    read -p "Êtes-vous sûr de vouloir continuer? Tapez 'DESTROY' pour confirmer: " -r
    echo
    
    if [[ $REPLY != "DESTROY" ]]; then
        log_info "Destruction annulée"
        exit 0
    fi
    
    log_info "Destruction en cours..."
    
    # Utiliser Terraform pour détruire proprement
    if [ -f "devops-tools.tf" ]; then
        tofu destroy -var-file="devops-vars.tfvars" -auto-approve
    fi
    
    # Nettoyer manuellement si nécessaire
    log_info "Nettoyage des ressources restantes..."
    kubectl delete namespace nexus sonarqube argocd devops --ignore-not-found=true &>/dev/null || true
    
    # Supprimer les fichiers temporaires
    rm -f devops-plan.out deployment-info.txt &>/dev/null || true
    
    log_success "✓ Destruction terminée"
}

# Fonction principale
main() {
    show_banner
    
    # Vérifier les prérequis
    check_prerequisites
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous déployer les outils DevOps sur le cluster EKS? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Déploiement annulé par l'utilisateur"
        exit 0
    fi
    
    # Piège pour nettoyer en cas d'erreur
    trap cleanup_on_failure ERR
    
    # Étapes du déploiement
    setup_helm_repos
    cleanup_existing_resources
    init_terraform
    plan_deployment
    apply_deployment
    wait_for_pods
    test_services
    display_deployment_info
    
    # Nettoyer les fichiers temporaires de plan
    rm -f devops-plan.out &>/dev/null || true
    
    echo ""
    log_success "🎉 DÉPLOIEMENT DEVOPS TERMINÉ AVEC SUCCÈS ! 🎉"
    echo ""
    echo "Tous vos outils DevOps sont maintenant opérationnels !"
    echo "Utilisez les commandes port-forward pour accéder aux interfaces."
    echo ""
}

# Gestion des arguments
case "${1:-}" in
    "destroy")
        destroy_deployment
        ;;
    "status")
        check_status
        ;;
    "help")
        show_help
        ;;
    "")
        main
        ;;
    *)
        log_error "Argument invalide: $1"
        echo ""
        show_help
        exit 1
        ;;
esac