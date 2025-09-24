#!/bin/bash

# =============================================================================
# SCRIPT SIMPLE DE CRÉATION DES LOADBALANCERS POUR LES OUTILS DEVOPS
# Version simplifiée pour nouveau cluster EKS
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
    echo -e "    🌐 EXPOSITION DES SERVICES DEVOPS"
    echo -e "    📦 Nexus • SonarQube • ArgoCD"
    echo -e "    🔧 Version simplifiée pour nouveau cluster"
    echo -e "================================================${NC}"
    echo ""
}

# Vérification des prérequis de base
check_prerequisites() {
    log_step "🔍 VÉRIFICATION DES PRÉREQUIS"
    
    # Vérifier les outils
    local tools=("kubectl" "aws")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool non trouvé. Veuillez l'installer d'abord."
            exit 1
        fi
        log_success "✅ $tool disponible"
    done
    
    # Vérifier l'accès au cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Impossible d'accéder au cluster Kubernetes"
        exit 1
    fi
    log_success "✅ Accès au cluster confirmé"
    
    # Vérifier que les services DevOps existent
    local services=(
        "nexus-service:nexus"
        "sonarqube-sonarqube:sonarqube" 
        "argocd-server:argocd"
    )
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service namespace <<< "$service_info"
        if ! kubectl get svc "$service" -n "$namespace" &>/dev/null; then
            log_error "Service $service non trouvé dans le namespace $namespace"
            exit 1
        fi
        log_success "✅ Service $service trouvé dans $namespace"
    done
}

# Vérification simple du AWS Load Balancer Controller
check_controller() {
    log_step "🔍 VÉRIFICATION DU LOAD BALANCER CONTROLLER"
    
    # Vérifier si le controller existe
    if ! kubectl get deployment aws-load-balancer-controller -n kube-system &>/dev/null; then
        log_error "AWS Load Balancer Controller non trouvé"
        log_info "Installez d'abord le controller avec ./install-controller.sh"
        exit 1
    fi
    
    log_info "Vérification du statut du controller..."
    if kubectl wait --for=condition=available deployment aws-load-balancer-controller -n kube-system --timeout=30s &>/dev/null; then
        log_success "✅ Controller opérationnel"
    else
        log_warning "Controller pas complètement prêt, on continue quand même..."
    fi
}

# Lire les mots de passe depuis devops-vars.tfvars
read_credentials() {
    log_step "🔑 LECTURE DES IDENTIFIANTS"
    
    if [ -f "devops-vars.tfvars" ]; then
        NEXUS_PASSWORD=$(grep "nexus_admin_password" devops-vars.tfvars | cut -d'"' -f2 2>/dev/null || echo "nexus123")
        SONARQUBE_PASSWORD=$(grep "sonarqube_admin_password" devops-vars.tfvars | cut -d'"' -f2 2>/dev/null || echo "sonar123")
        ARGOCD_PASSWORD=$(grep "argocd_admin_password" devops-vars.tfvars | cut -d'"' -f2 2>/dev/null || echo "argocd123")
    else
        log_warning "Fichier devops-vars.tfvars non trouvé, utilisation de mots de passe par défaut"
        NEXUS_PASSWORD="nexus123"
        SONARQUBE_PASSWORD="sonar123"
        ARGOCD_PASSWORD="argocd123"
    fi
    
    log_success "✅ Identifiants configurés"
}

# Nettoyer les LoadBalancers existants
cleanup_existing_loadbalancers() {
    log_step "🧹 NETTOYAGE DES LOADBALANCERS EXISTANTS"
    
    log_info "Suppression des LoadBalancers existants..."
    kubectl delete svc nexus-loadbalancer -n nexus --ignore-not-found=true
    kubectl delete svc sonarqube-loadbalancer -n sonarqube --ignore-not-found=true
    kubectl delete svc argocd-loadbalancer -n argocd --ignore-not-found=true
    
    log_info "Attente de la suppression complète..."
    sleep 15
    log_success "✅ Nettoyage terminé"
}

# Créer les LoadBalancers avec configuration simple
create_loadbalancers() {
    log_step "🌐 CRÉATION DES LOADBALANCERS"
    
    log_info "Création du LoadBalancer pour Nexus..."
    
    # LoadBalancer pour Nexus
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: nexus-loadbalancer
  namespace: nexus
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  labels:
    app: nexus
    service: loadbalancer
spec:
  type: LoadBalancer
  selector:
    app: nexus
  ports:
    - name: http
      port: 80
      targetPort: 8081
      protocol: TCP
    - name: docker
      port: 5000
      targetPort: 5000
      protocol: TCP
  sessionAffinity: None
EOF
    
    log_success "✅ LoadBalancer Nexus créé"
    
    log_info "Création du LoadBalancer pour SonarQube..."
    
    # LoadBalancer pour SonarQube
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: sonarqube-loadbalancer
  namespace: sonarqube
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  labels:
    app: sonarqube
    service: loadbalancer
spec:
  type: LoadBalancer
  selector:
    app: sonarqube
    release: sonarqube
  ports:
    - name: http
      port: 80
      targetPort: 9000
      protocol: TCP
  sessionAffinity: None
EOF
    
    log_success "✅ LoadBalancer SonarQube créé"
    
    log_info "Création du LoadBalancer pour ArgoCD..."
    
    # LoadBalancer pour ArgoCD
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: argocd-loadbalancer
  namespace: argocd
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  labels:
    app: argocd
    service: loadbalancer
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: argocd-server
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: grpc
      port: 443
      targetPort: 8080
      protocol: TCP
  sessionAffinity: None
EOF
    
    log_success "✅ LoadBalancer ArgoCD créé"
    log_info "Tous les LoadBalancers ont été créés avec succès"
}

# Attendre que les LoadBalancers obtiennent leurs adresses externes
wait_for_external_ips() {
    log_step "⏳ ATTENTE DES ADRESSES IP EXTERNES"
    
    log_warning "Ceci peut prendre 3-5 minutes pour que AWS provisionne les Load Balancers..."
    
    local services=(
        "nexus-loadbalancer:nexus"
        "sonarqube-loadbalancer:sonarqube"
        "argocd-loadbalancer:argocd"
    )
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service namespace <<< "$service_info"
        
        log_info "Attente de l'IP externe pour $service dans $namespace..."
        
        local max_attempts=30
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            EXTERNAL_IP=$(kubectl get svc "$service" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            
            if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
                log_success "✅ $service: $EXTERNAL_IP"
                break
            fi
            
            # Vérifier s'il y a des erreurs périodiquement
            if [ $((attempt % 5)) -eq 0 ]; then
                log_info "Vérification des événements pour $service..."
                kubectl get events -n "$namespace" --field-selector involvedObject.name="$service" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -1 | grep -E "Warning|Error" || true
            fi
            
            log_info "Tentative $attempt/$max_attempts - En attente de l'IP externe pour $service..."
            sleep 10
            ((attempt++))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log_error "Timeout: Impossible d'obtenir l'IP externe pour $service"
            log_info "Vérifiez manuellement avec: kubectl describe svc $service -n $namespace"
        fi
    done
}

# Récupérer et afficher les URLs d'accès
get_service_urls() {
    log_step "🌐 RÉCUPÉRATION DES URLS D'ACCÈS"
    
    # Récupérer les IPs externes
    NEXUS_URL=$(kubectl get svc nexus-loadbalancer -n nexus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    SONARQUBE_URL=$(kubectl get svc sonarqube-loadbalancer -n sonarqube -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    ARGOCD_URL=$(kubectl get svc argocd-loadbalancer -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    # Vérifier si toutes les URLs sont disponibles
    local all_ready=true
    
    if [ -z "$NEXUS_URL" ] || [ "$NEXUS_URL" = "null" ]; then
        log_warning "⚠️  URL Nexus non encore disponible"
        all_ready=false
    fi
    
    if [ -z "$SONARQUBE_URL" ] || [ "$SONARQUBE_URL" = "null" ]; then
        log_warning "⚠️  URL SonarQube non encore disponible"
        all_ready=false
    fi
    
    if [ -z "$ARGOCD_URL" ] || [ "$ARGOCD_URL" = "null" ]; then
        log_warning "⚠️  URL ArgoCD non encore disponible"
        all_ready=false
    fi
    
    if [ "$all_ready" = false ]; then
        log_warning "Certaines URLs ne sont pas encore prêtes. Attendez quelques minutes et relancez le script."
        log_info "Vous pouvez vérifier l'état avec: kubectl get svc --all-namespaces | grep LoadBalancer"
        return 1
    fi
    
    return 0
}

# Tester la connectivité des services
test_service_connectivity() {
    log_step "🧪 TEST DE CONNECTIVITÉ DES SERVICES"
    
    log_info "Test de connectivité vers les LoadBalancers..."
    
    # Test Nexus
    if [ -n "$NEXUS_URL" ]; then
        log_info "Test de Nexus..."
        if timeout 10 curl -s --head "http://$NEXUS_URL" > /dev/null 2>&1; then
            log_success "✅ Nexus est accessible"
        else
            log_warning "⚠️  Nexus pourrait encore démarrer..."
        fi
    fi
    
    # Test SonarQube
    if [ -n "$SONARQUBE_URL" ]; then
        log_info "Test de SonarQube..."
        if timeout 10 curl -s --head "http://$SONARQUBE_URL" > /dev/null 2>&1; then
            log_success "✅ SonarQube est accessible"
        else
            log_warning "⚠️  SonarQube pourrait encore démarrer..."
        fi
    fi
    
    # Test ArgoCD
    if [ -n "$ARGOCD_URL" ]; then
        log_info "Test d'ArgoCD..."
        if timeout 10 curl -s --head "http://$ARGOCD_URL" > /dev/null 2>&1; then
            log_success "✅ ArgoCD est accessible"
        else
            log_warning "⚠️  ArgoCD pourrait encore démarrer..."
        fi
    fi
    
    log_info "Note: Les services peuvent prendre quelques minutes supplémentaires pour être complètement opérationnels"
}

# Afficher les informations d'accès
display_access_info() {
    log_step "📋 INFORMATIONS D'ACCÈS AUX SERVICES"
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 SERVICES DEVOPS EXPOSÉS AVEC SUCCÈS ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}🌐 URLS D'ACCÈS EXTERNES:${NC}"
    echo ""
    
    if [ -n "$NEXUS_URL" ] && [ "$NEXUS_URL" != "null" ]; then
        echo -e "${BOLD}${YELLOW}📦 NEXUS REPOSITORY MANAGER:${NC}"
        echo "   🌐 URL: http://$NEXUS_URL"
        echo "   👤 Username: admin"
        echo "   🔐 Password: $NEXUS_PASSWORD"
        echo ""
    fi
    
    if [ -n "$SONARQUBE_URL" ] && [ "$SONARQUBE_URL" != "null" ]; then
        echo -e "${BOLD}${YELLOW}🔍 SONARQUBE:${NC}"
        echo "   🌐 URL: http://$SONARQUBE_URL"
        echo "   👤 Username: admin"
        echo "   🔐 Password: $SONARQUBE_PASSWORD"
        echo ""
    fi
    
    if [ -n "$ARGOCD_URL" ] && [ "$ARGOCD_URL" != "null" ]; then
        echo -e "${BOLD}${YELLOW}🚀 ARGOCD:${NC}"
        echo "   🌐 URL: http://$ARGOCD_URL"
        echo "   👤 Username: admin"
        echo "   🔐 Password: $ARGOCD_PASSWORD"
        echo ""
    fi
    
    echo -e "${BOLD}${PURPLE}🛠️  COMMANDES UTILES:${NC}"
    echo "   • Voir les LoadBalancers: kubectl get svc --all-namespaces | grep LoadBalancer"
    echo "   • Supprimer les LoadBalancers: $0 destroy"
    echo "   • Vérifier l'état des pods: kubectl get pods --all-namespaces"
    echo ""
    
    echo -e "${BOLD}${BLUE}💡 NOTES IMPORTANTES:${NC}"
    echo "   • Les LoadBalancers AWS peuvent prendre quelques minutes pour être entièrement fonctionnels"
    echo "   • Les services utilisent des Network Load Balancers (NLB) pour de meilleures performances"
    echo "   • Assurez-vous que vos Security Groups permettent le trafic sur les ports 80 et 443"
    echo "   • Pour HTTPS, vous devrez configurer un certificat SSL/TLS"
    echo ""
    
    # Sauvegarder les informations d'accès
    cat > devops-access-info.txt << EOF
=== INFORMATIONS D'ACCÈS AUX SERVICES DEVOPS ===
Date de création: $(date)
Cluster: $(kubectl config current-context 2>/dev/null || echo "unknown")

URLS D'ACCÈS:
=============

Nexus Repository Manager:
- URL: http://$NEXUS_URL
- Username: admin
- Password: $NEXUS_PASSWORD

SonarQube:
- URL: http://$SONARQUBE_URL
- Username: admin
- Password: $SONARQUBE_PASSWORD

ArgoCD:
- URL: http://$ARGOCD_URL
- Username: admin
- Password: $ARGOCD_PASSWORD

LOADBALANCERS AWS:
==================
Nexus LoadBalancer: $NEXUS_URL
SonarQube LoadBalancer: $SONARQUBE_URL
ArgoCD LoadBalancer: $ARGOCD_URL

COMMANDES UTILES:
================
kubectl get svc --all-namespaces | grep LoadBalancer
kubectl get pods --all-namespaces
$0 destroy (pour supprimer les LoadBalancers)

NOTES:
======
- Les services peuvent prendre quelques minutes pour être accessibles
- Vérifiez vos Security Groups AWS pour autoriser le trafic
- Pour HTTPS, configurez des certificats SSL/TLS
EOF
    
    log_success "Informations sauvegardées dans 'devops-access-info.txt'"
}

# Fonction pour détruire les LoadBalancers
destroy_loadbalancers() {
    log_step "💥 SUPPRESSION DES LOADBALANCERS"
    
    log_warning "ATTENTION: Cette action va supprimer tous les LoadBalancers !"
    log_warning "Les services ne seront plus accessibles depuis l'extérieur !"
    echo ""
    read -p "Êtes-vous sûr de vouloir continuer? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Suppression annulée"
        exit 0
    fi
    
    log_info "Suppression des LoadBalancers en cours..."
    
    # Supprimer les LoadBalancers
    kubectl delete svc nexus-loadbalancer -n nexus --ignore-not-found=true
    kubectl delete svc sonarqube-loadbalancer -n sonarqube --ignore-not-found=true
    kubectl delete svc argocd-loadbalancer -n argocd --ignore-not-found=true
    
    # Nettoyer le fichier d'informations
    rm -f devops-access-info.txt &>/dev/null || true
    
    log_success "✅ LoadBalancers supprimés avec succès"
    log_info "Les services sont maintenant accessibles uniquement via port-forward"
}

# Fonction pour vérifier le statut
check_status() {
    log_step "📊 STATUT DES LOADBALANCERS"
    
    echo -e "${BOLD}${BLUE}État des LoadBalancers:${NC}"
    kubectl get svc --all-namespaces | grep LoadBalancer || echo "Aucun LoadBalancer trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}URLs d'accès actuelles:${NC}"
    
    # Vérifier Nexus
    NEXUS_URL=$(kubectl get svc nexus-loadbalancer -n nexus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$NEXUS_URL" ] && [ "$NEXUS_URL" != "null" ]; then
        echo "Nexus: http://$NEXUS_URL"
    else
        echo "Nexus: LoadBalancer non prêt"
    fi
    
    # Vérifier SonarQube
    SONARQUBE_URL=$(kubectl get svc sonarqube-loadbalancer -n sonarqube -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$SONARQUBE_URL" ] && [ "$SONARQUBE_URL" != "null" ]; then
        echo "SonarQube: http://$SONARQUBE_URL"
    else
        echo "SonarQube: LoadBalancer non prêt"
    fi
    
    # Vérifier ArgoCD
    ARGOCD_URL=$(kubectl get svc argocd-loadbalancer -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -n "$ARGOCD_URL" ] && [ "$ARGOCD_URL" != "null" ]; then
        echo "ArgoCD: http://$ARGOCD_URL"
    else
        echo "ArgoCD: LoadBalancer non prêt"
    fi
    
    # Vérifier les erreurs
    echo ""
    echo -e "${BOLD}${BLUE}Vérification des erreurs récentes:${NC}"
    local recent_errors=$(kubectl get events --all-namespaces --sort-by='.lastTimestamp' | grep -E "loadbalancer|FailedBuildModel" | grep -i "warning\|error" | tail -3)
    if [ -n "$recent_errors" ]; then
        echo "$recent_errors"
    else
        echo "Aucune erreur récente détectée"
    fi
}

# Fonction pour afficher l'aide
show_help() {
    echo -e "${BOLD}${BLUE}Usage: $0 [OPTION]${NC}"
    echo ""
    echo "Options:"
    echo "  (aucune)  Création des LoadBalancers et affichage des URLs"
    echo "  status    Affichage du statut des LoadBalancers"
    echo "  destroy   Suppression de tous les LoadBalancers"
    echo "  help      Affichage de cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0           # Créer les LoadBalancers"
    echo "  $0 status    # Vérifier le statut"
    echo "  $0 destroy   # Supprimer les LoadBalancers"
    echo ""
    echo -e "${BOLD}${CYAN}Fonctionnalités de cette version simplifiée:${NC}"
    echo "  ✅ Vérification simple du Load Balancer Controller"
    echo "  ✅ Création directe des LoadBalancers"
    echo "  ✅ Attente et vérification des adresses externes"
    echo "  ✅ Test de connectivité"
    echo "  ✅ Affichage des informations d'accès"
    echo ""
}

# Fonction principale
main() {
    show_banner
    
    # Vérifier les prérequis
    check_prerequisites
    
    # Vérifier le controller
    check_controller
    
    # Lire les identifiants
    read_credentials
    
    # Nettoyer les LoadBalancers existants
    cleanup_existing_loadbalancers
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous exposer les services DevOps via des LoadBalancers AWS? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Création des LoadBalancers annulée par l'utilisateur"
        exit 0
    fi
    
    # Étapes de création
    create_loadbalancers
    wait_for_external_ips
    
    # Récupérer les URLs et afficher les informations
    if get_service_urls; then
        test_service_connectivity
        display_access_info
        
        echo ""
        log_success "🎉 EXPOSITION DES SERVICES TERMINÉE AVEC SUCCÈS ! 🎉"
        echo ""
        echo "Vos services DevOps sont maintenant accessibles depuis Internet !"
        echo "Les URLs et identifiants sont sauvegardés dans 'devops-access-info.txt'"
        echo ""
    else
        log_warning "Certains LoadBalancers ne sont pas encore prêts."
        log_info "Attendez quelques minutes et relancez: $0 status"
        
        # Afficher les commandes de diagnostic
        echo ""
        echo -e "${BOLD}${YELLOW}🔧 COMMANDES DE DIAGNOSTIC:${NC}"
        echo "kubectl get events --all-namespaces | grep LoadBalancer"
        echo "kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
        echo "kubectl describe svc --all-namespaces | grep LoadBalancer"
    fi
}

# Gestion des arguments
case "${1:-}" in
    "destroy")
        read_credentials 2>/dev/null || true  # Ignorer l'erreur si pas de fichier vars
        destroy_loadbalancers
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