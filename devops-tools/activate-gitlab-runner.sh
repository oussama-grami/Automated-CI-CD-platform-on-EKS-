#!/bin/bash

# =============================================================================
# SCRIPT D'ACTIVATION FINALE GITLAB RUNNER
# Fichier: activate-gitlab-runner.sh
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
    echo -e "    🚀 ACTIVATION FINALE GITLAB RUNNER"
    echo -e "    🔧 Correction du problème 403 Forbidden"
    echo -e "================================================${NC}"
    echo ""
}

# Variables globales
GITLAB_URL=""
GITLAB_TOKEN=""

# Lire la configuration
read_config() {
    log_step "📖 LECTURE DE LA CONFIGURATION"
    
    if [ -f "devops-vars.tfvars" ]; then
        GITLAB_URL=$(grep "gitlab_url" devops-vars.tfvars | cut -d'"' -f2)
        GITLAB_TOKEN=$(grep "gitlab_registration_token" devops-vars.tfvars | cut -d'"' -f2)
        
        log_success "✅ Configuration chargée"
        log_info "   - GitLab URL: $GITLAB_URL"
        log_info "   - Token: ${GITLAB_TOKEN:0:15}..."
    else
        log_error "❌ Fichier devops-vars.tfvars non trouvé"
        exit 1
    fi
}

# Vérifier l'état actuel du runner
check_runner_status() {
    log_step "🔍 VÉRIFICATION DE L'ÉTAT ACTUEL"
    
    local pod_name=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$pod_name" ]; then
        log_info "Runner pod trouvé: $pod_name"
        
        log_info "Logs récents:"
        kubectl logs "$pod_name" -n devops --tail=5
        echo ""
        
        # Analyser les logs
        local logs=$(kubectl logs "$pod_name" -n devops --tail=10 2>/dev/null)
        
        if echo "$logs" | grep -q "403 Forbidden"; then
            log_warning "⚠️ Problème 403 Forbidden détecté"
            return 1
        elif echo "$logs" | grep -q "Checking for jobs.*failed"; then
            log_warning "⚠️ Échec de récupération des jobs"
            return 1
        elif echo "$logs" | grep -q "Checking for jobs"; then
            log_success "✅ Runner fonctionne correctement"
            return 0
        else
            log_info "ℹ️ État indéterminé, vérification nécessaire"
            return 1
        fi
    else
        log_error "❌ Aucun pod GitLab Runner trouvé"
        return 1
    fi
}

# Re-enregistrer le runner avec une méthode différente
reregister_runner() {
    log_step "🔄 RE-ENREGISTREMENT DU RUNNER"
    
    log_info "Suppression du runner actuel pour ré-enregistrement..."
    kubectl delete deployment gitlab-runner -n devops --ignore-not-found=true
    sleep 10
    
    log_info "Création d'un nouveau deployment avec auto-registration..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-runner
  namespace: devops
  labels:
    app: gitlab-runner
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitlab-runner
  template:
    metadata:
      labels:
        app: gitlab-runner
    spec:
      serviceAccountName: gitlab-runner
      containers:
      - name: gitlab-runner
        image: gitlab/gitlab-runner:v16.6.1
        command: ["/bin/bash"]
        args:
          - -c
          - |
            # Enregistrer le runner au démarrage
            gitlab-runner register \
              --non-interactive \
              --url="$GITLAB_URL" \
              --registration-token="$GITLAB_TOKEN" \
              --executor="kubernetes" \
              --description="kubernetes-runner-$(hostname)" \
              --tag-list="kubernetes,docker" \
              --kubernetes-namespace="devops" \
              --kubernetes-privileged="true" \
              --kubernetes-image="ubuntu:20.04" \
              --kubernetes-cpu-limit="1000m" \
              --kubernetes-memory-limit="2Gi" \
              --kubernetes-cpu-request="100m" \
              --kubernetes-memory-request="128Mi"
            
            # Démarrer le runner
            exec gitlab-runner run
        env:
        - name: GITLAB_URL
          value: "$GITLAB_URL"
        - name: REGISTRATION_TOKEN
          value: "$GITLAB_TOKEN"
        - name: DOCKER_DRIVER
          value: "overlay2"
        - name: FF_KUBERNETES_HONOR_ENTRYPOINT
          value: "true"
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "1000m"
            memory: "1Gi"
        volumeMounts:
        - name: docker-certs
          mountPath: /certs/client
        livenessProbe:
          exec:
            command: ["/usr/bin/pgrep", "gitlab-runner"]
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["/usr/bin/pgrep", "gitlab-runner"]
          initialDelaySeconds: 30
          periodSeconds: 5
      volumes:
      - name: docker-certs
        emptyDir:
          medium: Memory
EOF

    log_success "✅ Nouveau deployment avec auto-registration créé"
}

# Attendre et vérifier le nouveau runner
wait_and_verify() {
    log_step "⏳ ATTENTE ET VÉRIFICATION"
    
    log_info "Attente que le nouveau pod soit prêt..."
    kubectl wait --for=condition=ready pod -l app=gitlab-runner -n devops --timeout=300s
    
    log_success "✅ Pod prêt"
    
    # Attendre l'enregistrement
    log_info "Surveillance de l'enregistrement (jusqu'à 3 minutes)..."
    local max_attempts=12
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local pod_name=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        local logs=$(kubectl logs "$pod_name" -n devops --tail=10 2>/dev/null || echo "")
        
        if echo "$logs" | grep -q "Runner registered successfully"; then
            log_success "✅ Runner enregistré avec succès !"
            break
        elif echo "$logs" | grep -q "Checking for jobs.*requests=0"; then
            log_success "✅ Runner actif - en attente de jobs !"
            break
        elif echo "$logs" | grep -q "403 Forbidden"; then
            log_error "❌ Encore un problème 403 - token invalide"
            return 1
        fi
        
        log_info "Tentative $attempt/$max_attempts - Enregistrement en cours..."
        sleep 15
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        log_warning "⚠️ Timeout - vérification manuelle nécessaire"
        return 1
    fi
}

# Test du pipeline
test_pipeline() {
    log_step "🧪 TEST DU PIPELINE"
    
    log_info "Vérification finale des logs du runner..."
    local pod_name=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    echo ""
    echo -e "${BOLD}${CYAN}📋 LOGS ACTUELS DU RUNNER:${NC}"
    kubectl logs "$pod_name" -n devops --tail=15
    echo ""
    
    local logs=$(kubectl logs "$pod_name" -n devops --tail=15 2>/dev/null)
    
    if echo "$logs" | grep -q -E "(Checking for jobs.*requests=0|Runner registered successfully)"; then
        log_success "✅ SUCCÈS: Runner fonctionnel !"
        return 0
    elif echo "$logs" | grep -q "403 Forbidden"; then
        log_error "❌ Problème persistant - token ou configuration GitLab"
        return 1
    else
        log_warning "⚠️ État incertain - vérification manuelle recommandée"
        return 1
    fi
}

# Instructions finales
display_final_instructions() {
    log_step "🎯 INSTRUCTIONS FINALES"
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 ACTIVATION DU GITLAB RUNNER TERMINÉE ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${BLUE}🚀 TESTER LE PIPELINE MAINTENANT:${NC}"
    echo ""
    echo "1. 🌐 Aller sur GitLab:"
    echo "   $GITLAB_URL/root/my-app/-/pipelines"
    echo ""
    echo "2. 🔄 Lancer un nouveau pipeline:"
    echo "   • Cliquer sur 'Run pipeline'"
    echo "   • Ou faire un commit/push"
    echo ""
    echo "3. ✅ Vérifier que le job s'exécute:"
    echo "   • Plus d'erreur 'no active runners'"
    echo "   • Le job doit passer en 'running'"
    echo ""
    
    echo -e "${BOLD}${YELLOW}🔍 SI LE PROBLÈME PERSISTE:${NC}"
    echo ""
    echo "1. 📋 Vérifier les runners dans GitLab:"
    echo "   Admin Area > CI/CD > Runners"
    echo ""
    echo "2. 🔧 Vérifier les logs en temps réel:"
    echo "   kubectl logs -f -l app=gitlab-runner -n devops"
    echo ""
    echo "3. 🔄 Si nécessaire, récupérer un nouveau token:"
    echo "   • Token expired → nouveau token registration"
    echo "   • Mettre à jour devops-vars.tfvars"
    echo ""
    
    echo -e "${BOLD}${CYAN}📊 COMMANDES DE DIAGNOSTIC:${NC}"
    echo "   • kubectl get pods -n devops -l app=gitlab-runner"
    echo "   • kubectl describe pod -l app=gitlab-runner -n devops"
    echo "   • kubectl get events -n devops --sort-by='.lastTimestamp'"
    echo ""
}

# Fonction principale
main() {
    show_banner
    
    # Vérifier les prérequis
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Impossible d'accéder au cluster Kubernetes"
        exit 1
    fi
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous activer et corriger le GitLab Runner définitivement ? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Activation annulée par l'utilisateur"
        exit 0
    fi
    
    # Processus d'activation
    read_config
    
    if check_runner_status; then
        log_success "✅ Runner déjà fonctionnel !"
        display_final_instructions
    else
        log_warning "⚠️ Problème détecté - re-enregistrement nécessaire"
        reregister_runner
        wait_and_verify
        if test_pipeline; then
            display_final_instructions
        else
            echo ""
            log_error "❌ Problème persistant"
            log_info "Vérifiez manuellement le token GitLab ou la connectivité"
        fi
    fi
    
    echo ""
    log_success "🎉 PROCESSUS D'ACTIVATION TERMINÉ !"
    echo ""
}

# Gestion des arguments
case "${1:-}" in
    "")
        main
        ;;
    "help")
        echo "Usage: $0"
        echo "Active et corrige définitivement le GitLab Runner"
        ;;
    *)
        log_error "Argument invalide: $1"
        exit 1
        ;;
esac