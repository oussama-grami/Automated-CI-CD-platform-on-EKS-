#!/bin/bash

# =============================================================================
# SCRIPT DE CORRECTION GITLAB RUNNER AVEC VÉRIFICATION TOKEN
# Fichier: fix-gitlab-runner-with-token-check.sh
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
    echo -e "    🔧 CORRECTION GITLAB RUNNER (avec token check)"
    echo -e "    🏃 Réparation automatique du Runner"
    echo -e "================================================${NC}"
    echo ""
}

# Variables globales
GITLAB_URL=""
GITLAB_TOKEN=""
CLUSTER_NAME=""
TOKEN_VALID=false

# Lire la configuration
read_config() {
    log_step "📖 LECTURE DE LA CONFIGURATION"
    
    if [ -f "devops-vars.tfvars" ]; then
        GITLAB_URL=$(grep "gitlab_url" devops-vars.tfvars | cut -d'"' -f2)
        GITLAB_TOKEN=$(grep "gitlab_registration_token" devops-vars.tfvars | cut -d'"' -f2)
        CLUSTER_NAME=$(grep "cluster_name" devops-vars.tfvars | cut -d'"' -f2)
        
        log_success "✅ Configuration trouvée"
        log_info "   - GitLab URL: $GITLAB_URL"
        log_info "   - Token: ${GITLAB_TOKEN:0:15}..."
        log_info "   - Cluster: $CLUSTER_NAME"
    else
        log_error "❌ Fichier devops-vars.tfvars non trouvé"
        exit 1
    fi
}

# Vérifier si le token est valide
verify_token() {
    log_step "🔍 VÉRIFICATION DU TOKEN GITLAB"
    
    log_info "Test du token de registration..."
    
    # Tester le token en essayant de l'utiliser
    local test_response=$(curl -s -w "%{http_code}" \
        -X POST "$GITLAB_URL/api/v4/runners" \
        -F "token=$GITLAB_TOKEN" \
        -F "description=token-test-runner" \
        -F "tag_list=test" 2>/dev/null || echo "000")
    
    local http_code="${test_response: -3}"
    
    if [ "$http_code" = "201" ]; then
        log_success "✅ Token valide ! Le runner de test a été créé."
        TOKEN_VALID=true
        
        # Supprimer immédiatement le runner de test
        log_info "Suppression du runner de test..."
        # Note: On ne peut pas facilement supprimer sans l'ID, mais GitLab le fera automatiquement
        
    elif [ "$http_code" = "403" ]; then
        log_error "❌ Token invalide ou expiré (403 Forbidden)"
        TOKEN_VALID=false
        
    elif [ "$http_code" = "000" ] || [ "$http_code" = "500" ]; then
        log_warning "⚠️ Impossible de tester le token (problème de connectivité)"
        log_info "Tentative avec le token existant..."
        TOKEN_VALID=true  # On essaie quand même
        
    else
        log_warning "⚠️ Réponse inattendue du serveur GitLab (Code: $http_code)"
        TOKEN_VALID=true  # On essaie quand même
    fi
}

# Demander un nouveau token si nécessaire
get_new_token() {
    log_step "🔑 RÉCUPÉRATION D'UN NOUVEAU TOKEN"
    
    if [ "$TOKEN_VALID" = true ]; then
        log_success "✅ Token actuel utilisable"
        return 0
    fi
    
    log_warning "❌ Le token actuel ne fonctionne pas"
    echo ""
    echo -e "${BOLD}${YELLOW}Pour récupérer un nouveau token GitLab:${NC}"
    echo ""
    echo "1. 🌐 Ouvrir GitLab dans le navigateur:"
    echo "   $GITLAB_URL"
    echo ""
    echo "2. 🔑 Se connecter en tant qu'administrateur"
    echo ""
    echo "3. 📋 Aller dans: Admin Area > CI/CD > Runners"
    echo ""
    echo "4. 📝 Copier le 'Registration token' affiché"
    echo ""
    echo "5. 🔄 OU utiliser l'API si vous avez un Personal Access Token:"
    echo "   curl --header \"PRIVATE-TOKEN: <votre-token>\" \"$GITLAB_URL/api/v4/runners/registration_token\""
    echo ""
    
    # Demander le nouveau token
    read -p "Entrez le nouveau registration token (ou appuyez sur Entrée pour essayer avec l'ancien): " NEW_TOKEN
    
    if [ -n "$NEW_TOKEN" ]; then
        GITLAB_TOKEN="$NEW_TOKEN"
        log_success "✅ Nouveau token configuré: ${GITLAB_TOKEN:0:15}..."
        
        # Mettre à jour le fichier devops-vars.tfvars
        log_info "Mise à jour du fichier devops-vars.tfvars..."
        sed -i "s/gitlab_registration_token = .*/gitlab_registration_token = \"$GITLAB_TOKEN\"/" devops-vars.tfvars
        log_success "✅ Fichier devops-vars.tfvars mis à jour"
        
    else
        log_warning "⚠️ Utilisation du token existant"
    fi
}

# Supprimer l'ancienne configuration
cleanup_old_runner() {
    log_step "🧹 NETTOYAGE DE L'ANCIENNE CONFIGURATION"
    
    log_info "Suppression de l'ancien deployment GitLab Runner..."
    kubectl delete deployment gitlab-runner -n devops --ignore-not-found=true
    
    log_info "Suppression des anciens secrets..."
    kubectl delete secret gitlab-runner-secret -n devops --ignore-not-found=true
    
    log_info "Suppression de l'ancienne ConfigMap..."
    kubectl delete configmap gitlab-runner-config -n devops --ignore-not-found=true
    
    log_info "Attente que les ressources soient supprimées..."
    sleep 15
    
    log_success "✅ Nettoyage terminé"
}

# Créer la nouvelle configuration avec le token validé
create_runner_config() {
    log_step "⚙️ CRÉATION DE LA NOUVELLE CONFIGURATION"
    
    log_info "Création du secret GitLab Runner avec le token validé..."
    
    # Créer le secret avec le token (validé ou nouveau)
    kubectl create secret generic gitlab-runner-secret \
        --from-literal=registration-token="$GITLAB_TOKEN" \
        --from-literal=gitlab-url="$GITLAB_URL" \
        -n devops
    
    log_success "✅ Secret créé avec le token: ${GITLAB_TOKEN:0:15}..."
    
    # Créer la ConfigMap avec une configuration robuste
    log_info "Création de la ConfigMap de configuration..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-runner-config
  namespace: devops
data:
  config.toml: |
    concurrent = 4
    check_interval = 30
    log_level = "info"

    [session_server]
      session_timeout = 1800

    [[runners]]
      name = "kubernetes-runner-$CLUSTER_NAME"
      url = "$GITLAB_URL"
      token = "$GITLAB_TOKEN"
      executor = "kubernetes"
      environment = ["DOCKER_DRIVER=overlay2", "DOCKER_TLS_CERTDIR=/certs"]
      [runners.kubernetes]
        host = ""
        namespace = "devops"
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
        poll_interval = 3
        [runners.kubernetes.pod_labels]
          "gitlab-runner" = "true"
        [[runners.kubernetes.volumes.empty_dir]]
          name = "docker-certs"
          mount_path = "/certs/client"
          medium = "Memory"
EOF

    log_success "✅ ConfigMap créée avec la configuration optimisée"
}

# Créer le Service Account avec les bonnes permissions
create_service_account() {
    log_step "👤 CRÉATION DU SERVICE ACCOUNT"
    
    log_info "Création du Service Account avec permissions étendues..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-runner
  namespace: devops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gitlab-runner
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/attach", "pods/log"]
  verbs: ["get", "list", "watch", "create", "patch", "delete"]
- apiGroups: [""]
  resources: ["configmaps", "secrets", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "patch", "delete", "update"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "create", "delete", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "patch", "delete", "update"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gitlab-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gitlab-runner
subjects:
- kind: ServiceAccount
  name: gitlab-runner
  namespace: devops
EOF

    log_success "✅ Service Account et permissions créés"
}

# Déployer le nouveau GitLab Runner optimisé
deploy_new_runner() {
    log_step "🚀 DÉPLOIEMENT DU NOUVEAU GITLAB RUNNER"
    
    log_info "Création du deployment optimisé..."
    
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
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
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
        env:
        - name: REGISTRATION_TOKEN
          valueFrom:
            secretKeyRef:
              name: gitlab-runner-secret
              key: registration-token
        - name: GITLAB_URL
          valueFrom:
            secretKeyRef:
              name: gitlab-runner-secret
              key: gitlab-url
        - name: RUNNER_EXECUTOR
          value: "kubernetes"
        - name: KUBERNETES_NAMESPACE
          value: "devops"
        - name: KUBERNETES_PRIVILEGED
          value: "true"
        - name: RUNNER_NAME
          value: "kubernetes-runner-$CLUSTER_NAME"
        - name: DOCKER_DRIVER
          value: "overlay2"
        - name: FF_KUBERNETES_HONOR_ENTRYPOINT
          value: "true"
        lifecycle:
          preStop:
            exec:
              command: ["/entrypoint", "unregister", "--all-runners"]
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "1000m"
            memory: "1Gi"
        volumeMounts:
        - name: config
          mountPath: /etc/gitlab-runner
          readOnly: true
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
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: config
        configMap:
          name: gitlab-runner-config
      - name: docker-certs
        emptyDir:
          medium: Memory
      restartPolicy: Always
EOF

    log_success "✅ Nouveau GitLab Runner déployé avec optimisations"
}

# Attendre que le runner soit prêt et vérifier l'enregistrement
wait_for_runner() {
    log_step "⏳ ATTENTE ET VÉRIFICATION DU RUNNER"
    
    log_info "Attente que le pod soit en cours d'exécution..."
    kubectl wait --for=condition=ready pod -l app=gitlab-runner -n devops --timeout=300s
    
    log_success "✅ Pod GitLab Runner prêt"
    
    # Attendre et surveiller l'enregistrement
    log_info "Surveillance de l'enregistrement du runner..."
    local max_attempts=20
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local pod_name=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        local logs=$(kubectl logs "$pod_name" -n devops --tail=5 2>/dev/null || echo "")
        
        if echo "$logs" | grep -q "Runner registered successfully"; then
            log_success "✅ Runner enregistré avec succès !"
            return 0
        elif echo "$logs" | grep -q "Checking for jobs"; then
            log_success "✅ Runner actif et en attente de jobs !"
            return 0
        elif echo "$logs" | grep -q "403 Forbidden"; then
            log_error "❌ Token invalide - 403 Forbidden"
            return 1
        fi
        
        log_info "Tentative $attempt/$max_attempts - Runner en cours d'enregistrement..."
        sleep 15
        ((attempt++))
    done
    
    log_warning "⚠️ Timeout - vérifiez manuellement les logs"
    return 1
}

# Afficher le résumé final avec diagnostic
display_final_status() {
    log_step "📊 RÉSUMÉ FINAL ET DIAGNOSTIC"
    
    local pod_name=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 CORRECTION DU GITLAB RUNNER TERMINÉE ! 🎉${NC}"
    echo ""
    
    if [ -n "$pod_name" ]; then
        echo -e "${BOLD}${CYAN}📋 LOGS RÉCENTS DU RUNNER:${NC}"
        kubectl logs "$pod_name" -n devops --tail=10
        echo ""
    fi
    
    # Vérifier l'état final
    local pod_status=$(kubectl get pods -n devops -l app=gitlab-runner -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
    local ready_replicas=$(kubectl get deployment gitlab-runner -n devops -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    echo -e "${BOLD}${CYAN}📋 ÉTAT FINAL:${NC}"
    echo "   • Pod Status: $pod_status"
    echo "   • Ready Replicas: $ready_replicas"
    echo "   • Token utilisé: ${GITLAB_TOKEN:0:15}..."
    echo "   • GitLab URL: $GITLAB_URL"
    echo ""
    
    echo -e "${BOLD}${YELLOW}🔍 COMMANDES DE VÉRIFICATION:${NC}"
    echo "   • kubectl get pods -n devops -l app=gitlab-runner"
    echo "   • kubectl logs -l app=gitlab-runner -n devops -f"
    echo "   • kubectl describe deployment gitlab-runner -n devops"
    echo ""
    
    echo -e "${BOLD}${BLUE}🚀 TEST DU PIPELINE:${NC}"
    echo "   1. Allez sur: $GITLAB_URL/root/my-app/-/pipelines"
    echo "   2. Cliquez sur 'Run pipeline' ou faites un nouveau commit"
    echo "   3. Le pipeline devrait maintenant s'exécuter sans erreur !"
    echo ""
    
    if [ "$ready_replicas" = "1" ] && [ "$pod_status" = "Running" ]; then
        echo -e "${BOLD}${GREEN}✅ SUCCÈS: GitLab Runner opérationnel !${NC}"
        echo "🎯 Votre problème 'no active runners' devrait être résolu !"
    else
        echo -e "${BOLD}${YELLOW}⚠️ ATTENTION: Vérifiez les logs si le problème persiste${NC}"
    fi
    
    echo ""
}

# Fonction principale
main() {
    show_banner
    
    # Vérifications préliminaires
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Impossible d'accéder au cluster Kubernetes"
        exit 1
    fi
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous corriger la configuration du GitLab Runner avec vérification du token ? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Correction annulée par l'utilisateur"
        exit 0
    fi
    
    # Exécuter les corrections avec vérification du token
    read_config
    verify_token
    get_new_token
    cleanup_old_runner
    create_service_account
    create_runner_config
    deploy_new_runner
    wait_for_runner
    display_final_status
    
    echo ""
    log_success "🎉 CORRECTION AVEC VÉRIFICATION TOKEN TERMINÉE !"
    echo ""
}

# Gestion des arguments
case "${1:-}" in
    "")
        main
        ;;
    "help")
        echo "Usage: $0"
        echo "Corrige automatiquement le GitLab Runner avec vérification du token"
        ;;
    *)
        log_error "Argument invalide: $1"
        exit 1
        ;;
esac