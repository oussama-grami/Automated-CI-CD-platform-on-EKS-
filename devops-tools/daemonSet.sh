#!/bin/bash

# Script de configuration automatique du registry Nexus
# Usage: ./configure_nexus_registry.sh <NEXUS_URL>

set -e

# Vérification des arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <NEXUS_URL>"
    echo "Exemple: $0 k8s-nexus-nexusdoc-6cad6cdf5b-ed3453ca4d918e75.elb.eu-west-1.amazonaws.com"
    exit 1
fi

NEXUS_URL="$1"
REGISTRY_URL="${NEXUS_URL}:8082"
NAMESPACE="my-app"
USERNAME="admin"
PASSWORD="admin123"

echo "=========================================="
echo "CONFIGURATION NEXUS REGISTRY"
echo "URL: $REGISTRY_URL"
echo "Date: $(date)"
echo "=========================================="

# Fonction pour nettoyer les anciennes configurations
cleanup_old_configs() {
    echo "Nettoyage des anciennes configurations..."
    
    # Supprimer les anciens DaemonSets
    kubectl delete daemonset -n kube-system -l app=configure-containerd-insecure --ignore-not-found=true
    
    echo "✓ Anciennes configurations supprimées"
}

# Créer le DaemonSet pour cette URL
create_daemonset() {
    echo "Création du DaemonSet pour $REGISTRY_URL..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: configure-containerd-${NEXUS_URL//[.-]/-}
  namespace: kube-system
  labels:
    app: configure-containerd-insecure
spec:
  selector:
    matchLabels:
      name: configure-containerd-${NEXUS_URL//[.-]/-}
  template:
    metadata:
      labels:
        name: configure-containerd-${NEXUS_URL//[.-]/-}
        app: configure-containerd-insecure
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: configure
        image: alpine:latest
        command: ["sh", "-c"]
        args:
        - |
          echo "Configuring containerd for registry: $REGISTRY_URL"
          
          # Créer le répertoire de configuration
          mkdir -p /host/etc/containerd/certs.d/$REGISTRY_URL
          
          # Configurer le registry comme insecure
          cat > /host/etc/containerd/certs.d/$REGISTRY_URL/hosts.toml << 'EOL'
          server = "http://$REGISTRY_URL"
          
          [host."http://$REGISTRY_URL"]
            capabilities = ["pull", "resolve", "push"]
            skip_verify = true
            plain_http = true
          EOL
          
          echo "Configuration created for $REGISTRY_URL"
          
          # Redémarrer containerd
          chroot /host systemctl restart containerd || echo "Failed to restart containerd"
          
          echo "Configuration applied, monitoring..."
          while true; do
            sleep 3600
          done
        securityContext:
          privileged: true
        volumeMounts:
        - name: host
          mountPath: /host
      volumes:
      - name: host
        hostPath:
          path: /
EOF
    
    echo "✓ DaemonSet créé"
}

# Générer la configuration Docker Registry Secret
generate_docker_config() {
    echo "Génération de la configuration Docker..."
    
    # Créer le docker config JSON
    DOCKER_CONFIG=$(cat <<EOF | base64 -w 0
{
  "auths": {
    "$REGISTRY_URL": {
      "username": "$USERNAME",
      "password": "$PASSWORD",
      "auth": "$(echo -n $USERNAME:$PASSWORD | base64 -w 0)"
    }
  }
}
EOF
)
    
    echo "✓ Configuration Docker générée"
    echo ""
    echo "=========================================="
    echo "DOCKER REGISTRY SECRET CONFIG"
    echo "=========================================="
    echo "Utilisez cette configuration dans votre registry-secret.yaml:"
    echo ""
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nexus-registry-secret
  namespace: $NAMESPACE
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $DOCKER_CONFIG
EOF
    echo ""
    echo "=========================================="
}

# Créer le secret dans Kubernetes
create_k8s_secret() {
    echo "Création du secret Kubernetes..."
    
    # Supprimer l'ancien secret s'il existe
    kubectl delete secret nexus-registry-secret -n $NAMESPACE --ignore-not-found=true
    
    # Créer le nouveau secret
    kubectl create secret docker-registry nexus-registry-secret \
      --docker-server=$REGISTRY_URL \
      --docker-username=$USERNAME \
      --docker-password=$PASSWORD \
      --namespace=$NAMESPACE
    
    echo "✓ Secret Kubernetes créé"
}

# Vérifier que le namespace existe
ensure_namespace() {
    if ! kubectl get namespace $NAMESPACE &>/dev/null; then
        echo "Création du namespace $NAMESPACE..."
        kubectl create namespace $NAMESPACE
        echo "✓ Namespace créé"
    else
        echo "✓ Namespace $NAMESPACE existe"
    fi
}

# Fonction principale
main() {
    ensure_namespace
    cleanup_old_configs
    create_daemonset
    create_k8s_secret
    generate_docker_config
    
    echo ""
    echo "=========================================="
    echo "CONFIGURATION TERMINÉE"
    echo "=========================================="
    echo "Registry URL: $REGISTRY_URL"
    echo "Namespace: $NAMESPACE"
    echo ""
    echo "Actions effectuées:"
    echo "- DaemonSet containerd configuré pour HTTP"
    echo "- Secret Kubernetes créé"
    echo "- Configuration .dockerconfigjson générée"
    echo ""
    echo "Commandes utiles:"
    echo "  kubectl get daemonset -n kube-system -l app=configure-containerd-insecure"
    echo "  kubectl get secret nexus-registry-secret -n $NAMESPACE"
    echo "  kubectl rollout restart deployment/my-app -n $NAMESPACE"
}

# Validation de l'URL
if [[ ! "$NEXUS_URL" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "Erreur: URL invalide. Utilisez uniquement le hostname sans http:// ni port"
    exit 1
fi

# Exécution
main