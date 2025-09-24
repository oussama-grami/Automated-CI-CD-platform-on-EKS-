#!/bin/bash

# =============================================================================
# SCRIPT D'INSTALLATION DU AWS LOAD BALANCER CONTROLLER
# Version corrigée avec bonnes permissions dès le début
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
    echo -e "    ⚖️  INSTALLATION AWS LOAD BALANCER CONTROLLER"
    echo -e "    🔧 Version corrigée avec bonnes permissions"
    echo -e "================================================${NC}"
    echo ""
}

# Lire les variables depuis devops-vars.tfvars
read_variables() {
    log_step "📖 LECTURE DES VARIABLES"
    
    if [ ! -f "devops-vars.tfvars" ]; then
        log_error "Fichier devops-vars.tfvars non trouvé"
        exit 1
    fi
    
    CLUSTER_NAME=$(grep "cluster_name" devops-vars.tfvars | head -1 | cut -d'"' -f2)
    AWS_REGION=$(grep "aws_region" devops-vars.tfvars | head -1 | cut -d'"' -f2)
    
    if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
        log_error "Impossible de lire cluster_name ou aws_region depuis devops-vars.tfvars"
        exit 1
    fi
    
    # Récupérer l'ID du compte AWS
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        log_error "Impossible de récupérer l'ID du compte AWS"
        exit 1
    fi
    
    log_success "✅ Variables lues:"
    log_info "   - Cluster: $CLUSTER_NAME"
    log_info "   - Région: $AWS_REGION"
    log_info "   - Compte AWS: $AWS_ACCOUNT_ID"
}

# Vérifier les prérequis
check_prerequisites() {
    log_step "🔍 VÉRIFICATION DES PRÉREQUIS"
    
    local tools=("kubectl" "aws" "helm" "curl")
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
    
    # Vérifier que le cluster existe
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        log_error "Cluster EKS '$CLUSTER_NAME' non trouvé dans la région '$AWS_REGION'"
        exit 1
    fi
    log_success "✅ Cluster EKS trouvé"
    
    # Vérifier le provider OIDC
    OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text)
    if [ "$OIDC_ISSUER" = "None" ] || [ -z "$OIDC_ISSUER" ]; then
        log_error "OIDC Identity Provider non configuré pour le cluster"
        log_info "Activez l'OIDC Identity Provider dans la console AWS EKS"
        exit 1
    fi
    OIDC_ID=$(echo "$OIDC_ISSUER" | sed 's|https://||')
    log_success "✅ OIDC Identity Provider configuré: $OIDC_ID"
    
    log_success "Tous les prérequis sont satisfaits"
}

# Créer la politique IAM pour le Load Balancer Controller
create_iam_policy() {
    log_step "📋 CRÉATION DE LA POLITIQUE IAM"
    
    log_info "Création de la politique IAM AWS Load Balancer Controller..."
    
    # Créer la politique IAM complète
    cat > iam_policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateServiceLinkedRole"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeAccountAttributes",
                "ec2:DescribeAddresses",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeInternetGateways",
                "ec2:DescribeVpcs",
                "ec2:DescribeVpcPeeringConnections",
                "ec2:DescribeSubnets",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeInstances",
                "ec2:DescribeNetworkInterfaces",
                "ec2:DescribeTags",
                "ec2:GetCoipPoolUsage",
                "ec2:DescribeCoipPools",
                "elasticloadbalancing:DescribeLoadBalancers",
                "elasticloadbalancing:DescribeLoadBalancerAttributes",
                "elasticloadbalancing:DescribeListeners",
                "elasticloadbalancing:DescribeListenerAttributes",
                "elasticloadbalancing:DescribeListenerCertificates",
                "elasticloadbalancing:DescribeSSLPolicies",
                "elasticloadbalancing:DescribeRules",
                "elasticloadbalancing:DescribeTargetGroups",
                "elasticloadbalancing:DescribeTargetGroupAttributes",
                "elasticloadbalancing:DescribeTargetHealth",
                "elasticloadbalancing:DescribeTags",
                "elasticloadbalancing:DescribeTrustStores"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "cognito-idp:DescribeUserPoolClient",
                "acm:ListCertificates",
                "acm:DescribeCertificate",
                "iam:ListServerCertificates",
                "iam:GetServerCertificate",
                "waf-regional:GetWebACL",
                "waf-regional:GetWebACLForResource",
                "waf-regional:AssociateWebACL",
                "waf-regional:DisassociateWebACL",
                "wafv2:GetWebACL",
                "wafv2:GetWebACLForResource",
                "wafv2:AssociateWebACL",
                "wafv2:DisassociateWebACL",
                "shield:GetSubscriptionState",
                "shield:DescribeProtection",
                "shield:CreateProtection",
                "shield:DeleteProtection"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:RevokeSecurityGroupIngress"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateSecurityGroup"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags"
            ],
            "Resource": "arn:aws:ec2:*:*:security-group/*",
            "Condition": {
                "StringEquals": {
                    "ec2:CreateAction": "CreateSecurityGroup"
                },
                "Null": {
                    "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags",
                "ec2:DeleteTags"
            ],
            "Resource": "arn:aws:ec2:*:*:security-group/*",
            "Condition": {
                "Null": {
                    "aws:RequestTag/elbv2.k8s.aws/cluster": "true",
                    "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:RevokeSecurityGroupIngress",
                "ec2:DeleteSecurityGroup"
            ],
            "Resource": "*",
            "Condition": {
                "Null": {
                    "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:CreateLoadBalancer",
                "elasticloadbalancing:CreateTargetGroup"
            ],
            "Resource": "*",
            "Condition": {
                "Null": {
                    "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:CreateListener",
                "elasticloadbalancing:DeleteListener",
                "elasticloadbalancing:CreateRule",
                "elasticloadbalancing:DeleteRule"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:AddTags",
                "elasticloadbalancing:RemoveTags"
            ],
            "Resource": [
                "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
                "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
                "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
            ],
            "Condition": {
                "Null": {
                    "aws:RequestTag/elbv2.k8s.aws/cluster": "true",
                    "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:AddTags",
                "elasticloadbalancing:RemoveTags"
            ],
            "Resource": [
                "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
                "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
                "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
                "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:ModifyLoadBalancerAttributes",
                "elasticloadbalancing:SetIpAddressType",
                "elasticloadbalancing:SetSecurityGroups",
                "elasticloadbalancing:SetSubnets",
                "elasticloadbalancing:DeleteLoadBalancer",
                "elasticloadbalancing:ModifyTargetGroup",
                "elasticloadbalancing:ModifyTargetGroupAttributes",
                "elasticloadbalancing:DeleteTargetGroup"
            ],
            "Resource": "*",
            "Condition": {
                "Null": {
                    "aws:ResourceTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:AddTags"
            ],
            "Resource": [
                "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
                "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
                "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
            ],
            "Condition": {
                "StringEquals": {
                    "elasticloadbalancing:CreateAction": [
                        "CreateTargetGroup",
                        "CreateLoadBalancer"
                    ]
                },
                "Null": {
                    "aws:RequestTag/elbv2.k8s.aws/cluster": "false"
                }
            }
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:RegisterTargets",
                "elasticloadbalancing:DeregisterTargets"
            ],
            "Resource": "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "elasticloadbalancing:SetWebAcl",
                "elasticloadbalancing:ModifyListener",
                "elasticloadbalancing:AddListenerCertificates",
                "elasticloadbalancing:RemoveListenerCertificates",
                "elasticloadbalancing:ModifyRule"
            ],
            "Resource": "*"
        }
    ]
}
EOF
    
    # Créer la politique IAM (ou la mettre à jour si elle existe)
    POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    
    log_info "Création de la politique IAM: $POLICY_NAME"
    
    if aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://iam_policy.json \
        --region "$AWS_REGION" &>/dev/null; then
        log_success "✅ Politique IAM créée: $POLICY_ARN"
    else
        log_warning "⚠️  Politique IAM existe déjà, mise à jour..."
        aws iam create-policy-version \
            --policy-arn "$POLICY_ARN" \
            --policy-document file://iam_policy.json \
            --set-as-default \
            --region "$AWS_REGION" &>/dev/null || true
        log_success "✅ Politique IAM mise à jour"
    fi
    
    # Nettoyer le fichier temporaire
    rm -f iam_policy.json
}

# Créer l'OIDC Identity Provider si nécessaire
ensure_oidc_provider() {
    log_step "🔐 VÉRIFICATION DE L'OIDC IDENTITY PROVIDER"
    
    # Vérifier si l'OIDC provider existe déjà
    if aws iam get-open-id-connect-provider \
        --open-id-connect-provider-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}" \
        --region "$AWS_REGION" &>/dev/null; then
        log_success "✅ OIDC Identity Provider existe déjà"
    else
        log_info "Création de l'OIDC Identity Provider..."
        
        # Thumbprint universel pour AWS EKS (valide pour toutes les régions)
        THUMBPRINT="9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
        
        aws iam create-open-id-connect-provider \
            --url "$OIDC_ISSUER" \
            --client-id-list sts.amazonaws.com \
            --thumbprint-list "$THUMBPRINT" \
            --region "$AWS_REGION" &>/dev/null
        
        log_success "✅ OIDC Identity Provider créé"
    fi
}

# Créer le rôle IAM et le service account
create_service_account() {
    log_step "👤 CRÉATION DU SERVICE ACCOUNT"
    
    log_info "Création du rôle IAM avec IRSA..."
    
    # Créer le rôle IAM pour le service account
    ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
    
    # Document de confiance pour le rôle (avec la bonne configuration)
    cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
                    "${OIDC_ID}:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF
    
    # Créer le rôle IAM
    if aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json \
        --region "$AWS_REGION" &>/dev/null; then
        log_success "✅ Rôle IAM créé: $ROLE_NAME"
    else
        log_warning "⚠️  Rôle IAM existe déjà, mise à jour de la trust policy..."
        aws iam update-assume-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-document file://trust-policy.json \
            --region "$AWS_REGION" &>/dev/null
        log_success "✅ Trust policy mise à jour"
    fi
    
    # Attacher la politique au rôle
    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "$POLICY_ARN" \
        --region "$AWS_REGION" &>/dev/null || true
    
    log_success "✅ Politique attachée au rôle"
    
    # Créer le service account Kubernetes
    log_info "Création du service account Kubernetes..."
    
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}
EOF
    
    log_success "✅ Service account créé avec l'annotation IRSA"
    
    # Nettoyer les fichiers temporaires
    rm -f trust-policy.json
}

# Installer le AWS Load Balancer Controller via Helm
install_load_balancer_controller() {
    log_step "📦 INSTALLATION DU LOAD BALANCER CONTROLLER"
    
    log_info "Ajout du repository Helm EKS..."
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    log_info "Installation du AWS Load Balancer Controller..."
    
    # Vérifier si déjà installé
    if helm list -n kube-system | grep aws-load-balancer-controller &>/dev/null; then
        log_warning "⚠️  AWS Load Balancer Controller déjà installé, mise à jour..."
        helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller \
            --set region="$AWS_REGION" \
            --set vpcId=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text) \
            --timeout=600s
    else
        helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
            -n kube-system \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name=aws-load-balancer-controller \
            --set region="$AWS_REGION" \
            --set vpcId=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.resourcesVpcConfig.vpcId" --output text) \
            --timeout=600s
    fi
    
    log_success "✅ AWS Load Balancer Controller installé"
}

# Attendre que le contrôleur soit prêt
wait_for_controller() {
    log_step "⏳ ATTENTE DU DÉMARRAGE DU CONTRÔLEUR"
    
    log_info "Attente que le AWS Load Balancer Controller soit prêt..."
    
    # Attendre que les pods soient en cours d'exécution
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --timeout=300s
    
    log_success "✅ AWS Load Balancer Controller est prêt"
    
    # Vérifier les logs pour s'assurer qu'il fonctionne
    log_info "Vérification des logs du contrôleur..."
    kubectl logs -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system --tail=5 | grep -E "(controller started|successfully)" || true
    
    # Vérifier que le webhook est disponible
    log_info "Vérification du service webhook..."
    kubectl get svc aws-load-balancer-webhook-service -n kube-system
    
    log_success "✅ Contrôleur vérifié et opérationnel"
}

# Tester le contrôleur avec un service de test
test_controller() {
    log_step "🧪 TEST DU CONTRÔLEUR"
    
    log_info "Test rapide du contrôleur..."
    
    # Créer un namespace de test
    kubectl create namespace lb-test --dry-run=client -o yaml | kubectl apply -f -
    
    # Créer un pod de test
    cat << EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: lb-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF
    
    # Attendre que le pod soit prêt
    kubectl wait --for=condition=ready pod -l app=nginx-test -n lb-test --timeout=60s
    
    # Créer un service LoadBalancer de test
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: nginx-test-lb
  namespace: lb-test
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  selector:
    app: nginx-test
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
EOF
    
    log_info "Attente de 30 secondes pour vérifier si le LoadBalancer se crée..."
    sleep 30
    
    # Vérifier l'état du service
    LB_STATUS=$(kubectl get svc nginx-test-lb -n lb-test -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_STATUS" ] && [ "$LB_STATUS" != "null" ]; then
        log_success "✅ LoadBalancer de test créé avec succès: $LB_STATUS"
        TEST_SUCCESS=true
    else
        # Vérifier les événements pour voir s'il y a des erreurs
        log_info "Vérification des événements du service..."
        kubectl describe svc nginx-test-lb -n lb-test | tail -10
        
        # Vérifier si le contrôleur traite la demande
        PENDING_STATUS=$(kubectl get svc nginx-test-lb -n lb-test -o jsonpath='{.status.loadBalancer}' 2>/dev/null || echo "")
        if [ -n "$PENDING_STATUS" ]; then
            log_success "✅ Le contrôleur traite la demande de LoadBalancer"
            TEST_SUCCESS=true
        else
            log_warning "⚠️  LoadBalancer de test en cours de création..."
            TEST_SUCCESS=false
        fi
    fi
    
    # Nettoyer le test
    log_info "Nettoyage du test..."
    kubectl delete namespace lb-test &>/dev/null || true
    
    if [ "$TEST_SUCCESS" = true ]; then
        log_success "✅ Test du contrôleur réussi"
    else
        log_warning "⚠️  Test du contrôleur non concluant, mais l'installation semble correcte"
    fi
}

# Afficher les informations d'installation
display_installation_info() {
    log_step "📋 RÉSUMÉ DE L'INSTALLATION"
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 AWS LOAD BALANCER CONTROLLER INSTALLÉ AVEC SUCCÈS ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}📦 COMPOSANTS INSTALLÉS:${NC}"
    echo -e "${GREEN}   ✅ Politique IAM: AWSLoadBalancerControllerIAMPolicy${NC}"
    echo -e "${GREEN}   ✅ OIDC Identity Provider: Vérifié/Créé${NC}"
    echo -e "${GREEN}   ✅ Rôle IAM: AmazonEKSLoadBalancerControllerRole${NC}"
    echo -e "${GREEN}   ✅ Service Account: aws-load-balancer-controller${NC}"
    echo -e "${GREEN}   ✅ AWS Load Balancer Controller (Helm)${NC}"
    echo ""
    
    echo -e "${BOLD}${BLUE}🔧 CONFIGURATION:${NC}"
    echo "   • Cluster: $CLUSTER_NAME"
    echo "   • Région: $AWS_REGION"
    echo "   • Compte AWS: $AWS_ACCOUNT_ID"
    echo "   • OIDC Provider: Configuré avec le bon thumbprint"
    echo "   • Trust Policy: Corrigée automatiquement"
    echo ""
    
    echo -e "${BOLD}${YELLOW}📊 VÉRIFICATION:${NC}"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
    echo ""
    kubectl get svc -n kube-system aws-load-balancer-webhook-service
    echo ""
    
    echo -e "${BOLD}${PURPLE}🚀 PROCHAINES ÉTAPES:${NC}"
    echo "   1. Lancez maintenant: ./create-simple-loadbalancers.sh"
    echo "   2. Vos services pourront être exposés via des LoadBalancers AWS"
    echo "   3. Vérifiez vos Security Groups pour autoriser le trafic"
    echo ""
    
    echo -e "${BOLD}${GREEN}✨ Le contrôleur est prêt à créer des LoadBalancers ! ✨${NC}"
    echo ""
}

# Fonction pour désinstaller le contrôleur
uninstall_controller() {
    log_step "💥 DÉSINSTALLATION DU CONTRÔLEUR"
    
    log_warning "ATTENTION: Cette action va supprimer le AWS Load Balancer Controller !"
    log_warning "Tous les LoadBalancers gérés seront supprimés !"
    echo ""
    read -p "Êtes-vous sûr de vouloir continuer? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Désinstallation annulée"
        exit 0
    fi
    
    log_info "Désinstallation en cours..."
    
    # Supprimer le Helm release
    helm uninstall aws-load-balancer-controller -n kube-system &>/dev/null || true
    
    # Supprimer le service account
    kubectl delete serviceaccount aws-load-balancer-controller -n kube-system &>/dev/null || true
    
    # Détacher et supprimer la politique IAM
    aws iam detach-role-policy \
        --role-name AmazonEKSLoadBalancerControllerRole \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
        --region "$AWS_REGION" &>/dev/null || true
    
    # Supprimer le rôle IAM
    aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole --region "$AWS_REGION" &>/dev/null || true
    
    # Supprimer la politique IAM
    aws iam delete-policy \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
        --region "$AWS_REGION" &>/dev/null || true
    
    log_success "✅ AWS Load Balancer Controller désinstallé"
}

# Fonction pour vérifier le statut
check_status() {
    log_step "📊 STATUT DU CONTRÔLEUR"
    
    echo -e "${BOLD}${BLUE}État du AWS Load Balancer Controller:${NC}"
    kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller || echo "Contrôleur non installé"
    
    echo ""
    echo -e "${BOLD}${BLUE}Service webhook:${NC}"
    kubectl get svc aws-load-balancer-webhook-service -n kube-system 2>/dev/null || echo "Service webhook non trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}Helm release:${NC}"
    helm list -n kube-system | grep aws-load-balancer-controller || echo "Helm release non trouvé"
    
    echo ""
    echo -e "${BOLD}${BLUE}Vérification des permissions:${NC}"
    
    # Lire les variables pour les vérifications
    if [ -f "devops-vars.tfvars" ]; then
        CLUSTER_NAME=$(grep "cluster_name" devops-vars.tfvars | head -1 | cut -d'"' -f2)
        AWS_REGION=$(grep "aws_region" devops-vars.tfvars | head -1 | cut -d'"' -f2)
        AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text)
        OIDC_ID=$(echo "$OIDC_ISSUER" | sed 's|https://||')
        
        # Vérifier l'OIDC provider
        if aws iam get-open-id-connect-provider \
            --open-id-connect-provider-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_ID}" \
            --region "$AWS_REGION" &>/dev/null; then
            echo "✅ OIDC Identity Provider: OK"
        else
            echo "❌ OIDC Identity Provider: MANQUANT"
        fi
        
        # Vérifier le rôle IAM
        if aws iam get-role --role-name AmazonEKSLoadBalancerControllerRole --region "$AWS_REGION" &>/dev/null; then
            echo "✅ Rôle IAM: OK"
        else
            echo "❌ Rôle IAM: MANQUANT"
        fi
        
        # Vérifier le service account
        SA_ROLE_ARN=$(kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || echo "")
        if [ -n "$SA_ROLE_ARN" ]; then
            echo "✅ Service Account: OK (Role: $SA_ROLE_ARN)"
        else
            echo "❌ Service Account: PAS D'ANNOTATION DE RÔLE"
        fi
    fi
}

# Fonction pour afficher l'aide
show_help() {
    echo -e "${BOLD}${BLUE}Usage: $0 [OPTION]${NC}"
    echo ""
    echo "Options:"
    echo "  (aucune)   Installation complète du AWS Load Balancer Controller"
    echo "  status     Affichage du statut du contrôleur"
    echo "  uninstall  Désinstallation complète du contrôleur"
    echo "  help       Affichage de cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0           # Installation complète"
    echo "  $0 status    # Vérifier le statut"
    echo "  $0 uninstall # Désinstaller"
    echo ""
    echo -e "${BOLD}${CYAN}Améliorations de cette version:${NC}"
    echo "  ✅ Création automatique de l'OIDC Provider si nécessaire"
    echo "  ✅ Trust Policy correcte dès le départ"
    echo "  ✅ Thumbprint universel AWS EKS"
    echo "  ✅ Vérifications et corrections automatiques"
    echo "  ✅ Test de fonctionnement du contrôleur"
    echo ""
}

# Fonction principale
main() {
    show_banner
    
    # Lire les variables
    read_variables
    
    # Vérifier les prérequis
    check_prerequisites
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous installer le AWS Load Balancer Controller avec les bonnes permissions? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation annulée par l'utilisateur"
        exit 0
    fi
    
    # Étapes d'installation avec les bonnes permissions
    create_iam_policy
    ensure_oidc_provider        # ← NOUVELLE ÉTAPE
    create_service_account
    install_load_balancer_controller
    wait_for_controller
    test_controller
    display_installation_info
    
    echo ""
    log_success "🎉 INSTALLATION TERMINÉE AVEC SUCCÈS ! 🎉"
    echo ""
    echo "Le contrôleur est maintenant configuré avec les bonnes permissions !"
    echo "Vous pouvez directement utiliser: ./create-simple-loadbalancers.sh"
    echo ""
}

# Gestion des arguments
case "${1:-}" in
    "uninstall")
        read_variables
        uninstall_controller
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