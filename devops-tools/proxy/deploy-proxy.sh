#!/bin/bash

# Script de déploiement du reverse proxy Nginx pour Nexus Docker Registry
# Usage: ./deploy_nginx_proxy.sh

set -e

# Configuration
NEXUS_NAMESPACE="nexus"
PROXY_NAME="nexus-docker-proxy"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Vérification des prérequis
check_prerequisites() {
    print_section "VÉRIFICATION DES PRÉREQUIS"
    
    # kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl n'est pas installé"
        exit 1
    fi
    print_success "kubectl disponible"
    
    # Connexion cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Pas de connexion au cluster Kubernetes"
        exit 1
    fi
    print_success "Connexion cluster OK"
    
    # Namespace Nexus
    if ! kubectl get namespace $NEXUS_NAMESPACE &> /dev/null; then
        print_error "Namespace '$NEXUS_NAMESPACE' n'existe pas"
        print_warning "Déployez d'abord Nexus avant le proxy"
        exit 1
    fi
    print_success "Namespace $NEXUS_NAMESPACE existe"
    
    # Service Nexus
    if ! kubectl get svc nexus-service -n $NEXUS_NAMESPACE &> /dev/null; then
        print_error "Service 'nexus-service' non trouvé"
        print_warning "Vérifiez que Nexus est déployé"
        exit 1
    fi
    print_success "Service Nexus trouvé"
    
    # Fichiers YAML requis
    REQUIRED_FILES=(
        "nginx-docker-proxy.yaml"
        "nginx-proxy-configmap.yaml"
    )
    
    for file in "${REQUIRED_FILES[@]}"; do
        if [ ! -f "$file" ]; then
            print_error "Fichier requis manquant: $file"
            exit 1
        fi
    done
    print_success "Tous les fichiers YAML présents"
}

# Nettoyage des ressources existantes
cleanup_existing() {
    print_section "NETTOYAGE RESSOURCES EXISTANTES"
    
    # Supprimer le deployment s'il existe
    if kubectl get deployment $PROXY_NAME -n $NEXUS_NAMESPACE &> /dev/null; then
        kubectl delete deployment $PROXY_NAME -n $NEXUS_NAMESPACE
        print_success "Ancien deployment supprimé"
    fi
    
    # Supprimer le service s'il existe
    if kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE &> /dev/null; then
        kubectl delete svc $PROXY_NAME -n $NEXUS_NAMESPACE
        print_success "Ancien service supprimé"
    fi
    
    # Supprimer la configmap s'elle existe
    if kubectl get configmap nexus-docker-proxy-conf -n $NEXUS_NAMESPACE &> /dev/null; then
        kubectl delete configmap nexus-docker-proxy-conf -n $NEXUS_NAMESPACE
        print_success "Ancienne configmap supprimée"
    fi
    
    # Attendre que les ressources soient complètement supprimées
    echo "Attente de la suppression complète..."
    sleep 10
}

# Déploiement du proxy
deploy_proxy() {
    print_section "DÉPLOIEMENT REVERSE PROXY NGINX"
    
    # Appliquer la ConfigMap
    echo "Application de la ConfigMap..."
    kubectl apply -f nginx-proxy-configmap.yaml 
    print_success "ConfigMap appliquée"
    
    # Appliquer le deployment et service
    echo "Application du deployment et service..."
    kubectl apply -f nginx-docker-proxy.yaml
    kubectl apply -f nginx-docker-proxy-service.yaml
    print_success "Deployment et service appliqués"
    
    # Attendre que le deployment soit prêt
    echo "Attente du déploiement..."
    kubectl wait --for=condition=available deployment/$PROXY_NAME -n $NEXUS_NAMESPACE --timeout=300s
    print_success "Deployment prêt"
    
    # Attendre que le LoadBalancer obtienne une IP externe
    echo "Attente de l'IP externe du LoadBalancer..."
    local retries=60
    local proxy_url=""
    
    while [ $retries -gt 0 ] && [ -z "$proxy_url" ]; do
        proxy_url=$(kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -z "$proxy_url" ]; then
            echo "Tentative $((61-retries))/60..."
            sleep 10
            retries=$((retries-1))
        fi
    done
    
    if [ -n "$proxy_url" ]; then
        print_success "LoadBalancer prêt: $proxy_url"
    else
        print_warning "LoadBalancer pas encore prêt (peut prendre quelques minutes)"
    fi
}

# Tests de validation
validate_deployment() {
    print_section "VALIDATION DU DÉPLOIEMENT"
    
    # Vérifier que le pod fonctionne
    local pod_status=$(kubectl get pods -l app=$PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$pod_status" = "Running" ]; then
        print_success "Pod proxy en cours d'exécution"
    else
        print_error "Pod proxy pas en état Running: $pod_status"
        kubectl get pods -l app=$PROXY_NAME -n $NEXUS_NAMESPACE
        return 1
    fi
    
    # Récupérer l'URL du proxy
    local proxy_url=$(kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    local proxy_port=$(kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8082")
    
    if [ -n "$proxy_url" ]; then
        echo "Test de connectivité..."
        # Test simple de connexion
        if curl -s --connect-timeout 10 -o /dev/null -w "%{http_code}" http://$proxy_url:$proxy_port/ | grep -q "200\|404"; then
            print_success "Proxy accessible via LoadBalancer"
        else
            print_warning "Proxy pas encore accessible (DNS peut prendre du temps)"
        fi
        
        # Test endpoint Docker
        echo "Test endpoint Docker /v2/..."
        if curl -s --connect-timeout 10 -u admin:admin123 http://$proxy_url:$proxy_port/v2/ &>/dev/null; then
            print_success "Endpoint Docker /v2/ accessible"
        else
            print_warning "Endpoint Docker pas encore accessible"
        fi
    else
        print_warning "LoadBalancer IP/hostname pas encore assigné"
    fi
}

# Affichage des informations finales
show_final_info() {
    print_section "INFORMATIONS FINALES"
    
    # URLs des services
    local nexus_url=$(kubectl get svc nexus-service -n $NEXUS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "en-attente")
    local proxy_url=$(kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "en-attente")
    local proxy_port=$(kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8082")
    
    echo "Services déployés:"
    echo "  Nexus UI:        http://$nexus_url:8081"
    echo "  Docker Registry: http://$proxy_url:$proxy_port"
    echo ""
    
    if [ "$proxy_url" != "en-attente" ]; then
        echo "Commandes Docker à utiliser:"
        echo "  docker login $proxy_url:$proxy_port -u admin -p admin123"
        echo "  docker tag monimage:latest $proxy_url:$proxy_port/monimage:latest"
        echo "  docker push $proxy_url:$proxy_port/monimage:latest"
        echo "  docker pull $proxy_url:$proxy_port/monimage:latest"
    else
        echo "Attendez quelques minutes pour que le LoadBalancer soit prêt,"
        echo "puis exécutez: kubectl get svc $PROXY_NAME -n $NEXUS_NAMESPACE"
    fi
    
    echo ""
    echo "Logs du proxy:"
    echo "  kubectl logs -f deployment/$PROXY_NAME -n $NEXUS_NAMESPACE"
    echo ""
    echo "Suppression du proxy:"
    echo "  kubectl delete -f nginx-docker-proxy.yaml"
    echo "  kubectl delete -f nginx-proxy-configmap.yaml"
}

# Fonction principale
main() {
    echo "============================================="
    echo "DÉPLOIEMENT REVERSE PROXY NGINX POUR NEXUS"
    echo "Date: $(date)"
    echo "============================================="
    
    check_prerequisites
    cleanup_existing
    deploy_proxy
    validate_deployment
    show_final_info
    
    print_success "Déploiement du proxy terminé avec succès"
}

# Exécution
main "$@"