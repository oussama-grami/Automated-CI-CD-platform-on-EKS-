#!/bin/bash

# Script simple pour déployer l'application via ArgoCD
# Usage: ./deploy_argocd.sh

set -e

APP_NAMESPACE="my-app"
ARGOCD_NAMESPACE="argocd"

# Couleurs
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}Déploiement application via ArgoCD${NC}"
echo "Date: $(date)"
echo ""

# Créer le namespace my-app
echo "Création du namespace $APP_NAMESPACE..."
kubectl create namespace $APP_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace créé${NC}"

# Déployer l'application ArgoCD
echo "Déploiement de l'application ArgoCD..."
kubectl apply -f app-argo.yaml
echo -e "${GREEN}✓ Application ArgoCD déployée${NC}"

# Attendre que l'application soit synchronisée
echo "Attente de la synchronisation ArgoCD..."
sleep 30

# Attendre que les ressources soient créées
echo "Attente que les ressources soient prêtes..."
kubectl wait --for=condition=available deployment/my-app -n $APP_NAMESPACE --timeout=300s 2>/dev/null || {
    echo -e "${YELLOW}Timeout atteint, vérification manuelle...${NC}"
}

# Attendre le LoadBalancer
echo "Attente de l'IP externe du LoadBalancer..."
retries=60
external_url=""

while [ $retries -gt 0 ] && [ -z "$external_url" ]; do
    external_url=$(kubectl get svc my-app-service -n $APP_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [ -z "$external_url" ]; then
        echo "Tentative $((61-retries))/60..."
        sleep 10
        retries=$((retries-1))
    fi
done

echo ""
echo "=========================================="
echo "DÉPLOIEMENT TERMINÉ"
echo "=========================================="

if [ -n "$external_url" ]; then
    echo -e "${GREEN}Application accessible à:${NC}"
    echo "URL: http://$external_url"
    echo "Health Check: http://$external_url/health"
    echo "API Docs: http://$external_url/docs"
else
    echo -e "${YELLOW}LoadBalancer pas encore prêt${NC}"
    echo "Exécutez cette commande pour obtenir l'URL:"
    echo "kubectl get svc my-app-service -n $APP_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
fi

echo ""
echo "État des ressources:"
kubectl get all -n $APP_NAMESPACE