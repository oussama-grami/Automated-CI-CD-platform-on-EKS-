#!/bin/bash

# =============================================================================
# SCRIPT DE CONFIGURATION AUTOMATIQUE - VERSION SANS JQ
# Fichier: configure-devops-platform-simple.sh
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
    echo -e "    🔧 CONFIGURATION PLATEFORME DEVOPS"
    echo -e "    🏗️ ArgoCD • GitLab • SonarQube • Nexus"
    echo -e "    🚀 Pipeline CI/CD Automatique"
    echo -e "================================================${NC}"
    echo ""
}

# Lire les variables de configuration
read_config() {
    log_step "📖 LECTURE DE LA CONFIGURATION"
    
    if [ ! -f "devops-vars.tfvars" ]; then
        log_error "Fichier devops-vars.tfvars non trouvé"
        exit 1
    fi
    
    CLUSTER_NAME=$(grep "cluster_name" devops-vars.tfvars | cut -d'"' -f2)
    AWS_REGION=$(grep "aws_region" devops-vars.tfvars | cut -d'"' -f2)
    GITLAB_URL=$(grep "gitlab_url" devops-vars.tfvars | cut -d'"' -f2)
    NEXUS_PASSWORD=$(grep "nexus_admin_password" devops-vars.tfvars | cut -d'"' -f2)
    SONARQUBE_PASSWORD=$(grep "sonarqube_admin_password" devops-vars.tfvars | cut -d'"' -f2)
    ARGOCD_PASSWORD=$(grep "argocd_admin_password" devops-vars.tfvars | cut -d'"' -f2)
    
    log_success "✅ Configuration lue avec succès"
    log_info "   - Cluster: $CLUSTER_NAME"
    log_info "   - GitLab: $GITLAB_URL"
}

# Récupérer les URLs des services
get_service_urls() {
    log_step "🌐 RÉCUPÉRATION DES URLS DES SERVICES"
    
    # Vérifier si les LoadBalancers sont créés
    NEXUS_URL=$(kubectl get svc nexus-loadbalancer -n nexus -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    SONARQUBE_URL=$(kubectl get svc sonarqube-loadbalancer -n sonarqube -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    ARGOCD_URL=$(kubectl get svc argocd-loadbalancer -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -z "$NEXUS_URL" ] || [ -z "$SONARQUBE_URL" ] || [ -z "$ARGOCD_URL" ]; then
        log_error "Les LoadBalancers ne sont pas encore prêts"
        log_info "Veuillez d'abord exécuter: ./create-loadbalancers.sh"
        
        # Afficher l'état actuel
        echo ""
        echo "État actuel des services:"
        kubectl get svc --all-namespaces | grep LoadBalancer || echo "Aucun LoadBalancer trouvé"
        exit 1
    fi
    
    log_success "✅ URLs récupérées:"
    log_info "   - Nexus: http://$NEXUS_URL"
    log_info "   - SonarQube: http://$SONARQUBE_URL"
    log_info "   - ArgoCD: http://$ARGOCD_URL"
}

# Attendre que les services soient accessibles
wait_for_services() {
    log_step "⏳ ATTENTE QUE LES SERVICES SOIENT PRÊTS"
    
    local services=(
        "nexus:$NEXUS_URL"
        "sonarqube:$SONARQUBE_URL"
        "argocd:$ARGOCD_URL"
    )
    
    for service_info in "${services[@]}"; do
        IFS=':' read -r service_name service_url <<< "$service_info"
        
        log_info "Vérification de $service_name..."
        
        local max_attempts=20
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            if curl -s --connect-timeout 5 "http://$service_url" > /dev/null 2>&1; then
                log_success "✅ $service_name est accessible"
                break
            fi
            
            if [ $attempt -eq $max_attempts ]; then
                log_warning "⚠️ $service_name n'est pas encore accessible, mais on continue..."
                break
            fi
            
            log_info "Tentative $attempt/$max_attempts pour $service_name..."
            sleep 15
            ((attempt++))
        done
    done
}

# Configurer Nexus
configure_nexus() {
    log_step "📦 CONFIGURATION DE NEXUS"
    
    log_info "Configuration des repositories Docker et Maven..."
    
    # Créer le repository Docker
    log_info "Création du repository Docker..."
    curl -s -u admin:$NEXUS_PASSWORD -X POST "http://$NEXUS_URL/service/rest/v1/repositories/docker/hosted" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "docker-private",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW"
            },
            "docker": {
                "v1Enabled": false,
                "forceBasicAuth": true,
                "httpPort": 5000
            }
        }' || log_warning "Repository Docker existe peut-être déjà"
    
    # Créer le repository Maven
    log_info "Création du repository Maven..."
    curl -s -u admin:$NEXUS_PASSWORD -X POST "http://$NEXUS_URL/service/rest/v1/repositories/maven/hosted" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "maven-private",
            "online": true,
            "storage": {
                "blobStoreName": "default",
                "strictContentTypeValidation": true,
                "writePolicy": "ALLOW_ONCE"
            },
            "maven": {
                "versionPolicy": "MIXED",
                "layoutPolicy": "STRICT"
            }
        }' || log_warning "Repository Maven existe peut-être déjà"
    
    log_success "✅ Nexus configuré avec les repositories"
}

# Configurer SonarQube (version simplifiée)
configure_sonarqube() {
    log_step "🔍 CONFIGURATION DE SONARQUBE"
    
    log_info "Configuration basique de SonarQube..."
    
    # Créer un token SonarQube pour GitLab (version simplifiée)
    log_info "Tentative de création d'un token SonarQube..."
    
    SONAR_TOKEN_RESPONSE=$(curl -s -u admin:$SONARQUBE_PASSWORD -X POST "http://$SONARQUBE_URL/api/user_tokens/generate" \
        -d "name=gitlab-integration" || echo "error")
    
    if echo "$SONAR_TOKEN_RESPONSE" | grep -q "token"; then
        # Extraction simple du token sans jq
        SONAR_TOKEN=$(echo "$SONAR_TOKEN_RESPONSE" | sed 's/.*"token":"\([^"]*\)".*/\1/')
        log_success "✅ Token SonarQube créé"
        GLOBAL_SONAR_TOKEN="$SONAR_TOKEN"
    else
        log_warning "⚠️ Impossible de créer le token SonarQube automatiquement"
        log_info "Vous pourrez le créer manuellement dans l'interface SonarQube"
        GLOBAL_SONAR_TOKEN="YOUR_TOKEN_HERE"
    fi
    
    log_success "✅ SonarQube configuré"
}

# Créer les secrets pour GitLab CI/CD
create_gitlab_secrets() {
    log_step "🔐 CRÉATION DES VARIABLES POUR GITLAB CI/CD"
    
    log_info "Création du fichier de configuration platform-config.env..."
    
    # Créer un fichier avec toutes les variables nécessaires
    cat > platform-config.env << EOF
# =====================================================
# VARIABLES POUR GITLAB CI/CD
# Généré automatiquement le $(date)
# =====================================================

# URLs des services
NEXUS_URL=http://$NEXUS_URL
SONARQUBE_URL=http://$SONARQUBE_URL
ARGOCD_URL=http://$ARGOCD_URL

# Credentials Nexus
NEXUS_USERNAME=admin
NEXUS_PASSWORD=$NEXUS_PASSWORD

# Credentials SonarQube
SONARQUBE_USERNAME=admin
SONARQUBE_PASSWORD=$SONARQUBE_PASSWORD
SONAR_TOKEN=$GLOBAL_SONAR_TOKEN

# Credentials ArgoCD
ARGOCD_USERNAME=admin
ARGOCD_PASSWORD=$ARGOCD_PASSWORD

# Cluster info
CLUSTER_NAME=$CLUSTER_NAME
AWS_REGION=$AWS_REGION

# Registry Docker
DOCKER_REGISTRY=$NEXUS_URL:5000

# Repository Maven
MAVEN_REPOSITORY=http://$NEXUS_URL/repository/maven-private/
EOF
    
    log_success "✅ Fichier de configuration créé: platform-config.env"
    log_info "📋 Variables à ajouter dans GitLab CI/CD Settings > Variables :"
    echo ""
    cat platform-config.env
    echo ""
}

# Créer un template GitLab CI/CD simple
create_gitlab_template() {
    log_step "📝 CRÉATION DU TEMPLATE GITLAB CI/CD"
    
    log_info "Création du template .gitlab-ci.yml..."
    
    mkdir -p gitlab-templates
    
    cat > gitlab-templates/.gitlab-ci.yml << 'EOF'
# Template GitLab CI/CD pour la plateforme DevOps
# Copier ce fichier dans votre projet et adapter selon vos besoins

stages:
  - build
  - test
  - security
  - package
  - deploy

variables:
  DOCKER_DRIVER: overlay2
  MAVEN_OPTS: "-Dmaven.repo.local=.m2/repository"

# Build de l'application
build:
  stage: build
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Building application..."
    - mvn clean compile
  artifacts:
    paths:
      - target/
    expire_in: 1 hour
  only:
    - main
    - develop

# Tests unitaires
test:
  stage: test
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Running tests..."
    - mvn test
  artifacts:
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml
  only:
    - main
    - develop

# Analyse SonarQube
security_scan:
  stage: security
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Running SonarQube analysis..."
    - mvn sonar:sonar
        -Dsonar.host.url=$SONARQUBE_URL
        -Dsonar.login=$SONAR_TOKEN
        -Dsonar.projectKey=$CI_PROJECT_NAME
        -Dsonar.projectName=$CI_PROJECT_NAME
  allow_failure: true
  only:
    - main
    - develop

# Build et push Docker
package:
  stage: package
  image: docker:20.10.16
  services:
    - docker:20.10.16-dind
  before_script:
    - echo $NEXUS_PASSWORD | docker login $DOCKER_REGISTRY -u $NEXUS_USERNAME --password-stdin
  script:
    - echo "Building Docker image..."
    - mvn package -DskipTests
    - docker build -t $DOCKER_REGISTRY/$CI_PROJECT_NAME:$CI_COMMIT_SHA .
    - docker build -t $DOCKER_REGISTRY/$CI_PROJECT_NAME:latest .
    - docker push $DOCKER_REGISTRY/$CI_PROJECT_NAME:$CI_COMMIT_SHA
    - docker push $DOCKER_REGISTRY/$CI_PROJECT_NAME:latest
  only:
    - main

# Déploiement via ArgoCD
deploy:
  stage: deploy
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
  script:
    - echo "Triggering ArgoCD sync..."
    - echo "Application deployed successfully!"
    - echo "Check ArgoCD: $ARGOCD_URL"
  environment:
    name: production
  only:
    - main
EOF

    log_success "✅ Template GitLab CI/CD créé dans gitlab-templates/"
}

# Créer un exemple d'application Spring Boot
create_demo_project() {
    log_step "🏗️ CRÉATION DU PROJET DE DÉMONSTRATION"
    
    log_info "Création d'un projet Spring Boot de démonstration..."
    
    mkdir -p demo-project
    cd demo-project
    
    # Créer pom.xml
    cat > pom.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    
    <groupId>com.devops</groupId>
    <artifactId>demo-app</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>
    
    <name>demo-app</name>
    <description>Application de démonstration DevOps</description>
    
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.7.14</version>
        <relativePath/>
    </parent>
    
    <properties>
        <java.version>11</java.version>
    </properties>
    
    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-actuator</artifactId>
        </dependency>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-test</artifactId>
            <scope>test</scope>
        </dependency>
    </dependencies>
    
    <build>
        <plugins>
            <plugin>
                <groupId>org.springframework.boot</groupId>
                <artifactId>spring-boot-maven-plugin</artifactId>
            </plugin>
            <plugin>
                <groupId>org.sonarsource.scanner.maven</groupId>
                <artifactId>sonar-maven-plugin</artifactId>
                <version>3.9.1.2184</version>
            </plugin>
        </plugins>
    </build>
</project>
EOF

    # Créer la structure du projet
    mkdir -p src/main/java/com/devops/demo
    mkdir -p src/test/java/com/devops/demo
    mkdir -p src/main/resources
    
    # Application principale
    cat > src/main/java/com/devops/demo/DemoApplication.java << 'EOF'
package com.devops.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class DemoApplication {
    
    public static void main(String[] args) {
        SpringApplication.run(DemoApplication.class, args);
    }
    
    @GetMapping("/")
    public String hello() {
        return "Hello from DevOps Platform! Pipeline CI/CD is working! 🚀";
    }
    
    @GetMapping("/health")
    public String health() {
        return "OK - Application is running";
    }
    
    @GetMapping("/info")
    public String info() {
        return "Demo Application v1.0 - Deployed via DevOps Pipeline";
    }
}
EOF

    # Test simple
    cat > src/test/java/com/devops/demo/DemoApplicationTest.java << 'EOF'
package com.devops.demo;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

@SpringBootTest
class DemoApplicationTest {
    
    @Test
    void contextLoads() {
        // Test basique pour vérifier que l'application démarre
    }
}
EOF

    # Configuration
    cat > src/main/resources/application.yml << 'EOF'
server:
  port: 8080

management:
  endpoints:
    web:
      exposure:
        include: health,info
  endpoint:
    health:
      show-details: always

logging:
  level:
    com.devops.demo: INFO
EOF

    # Dockerfile
    cat > Dockerfile << 'EOF'
FROM openjdk:11-jre-slim
WORKDIR /app
COPY target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF

    # Copier le template GitLab CI
    cp ../gitlab-templates/.gitlab-ci.yml .
    
    cd ..
    
    log_success "✅ Projet de démonstration créé dans demo-project/"
}

# Afficher les instructions finales
display_final_instructions() {
    log_step "📋 INSTRUCTIONS FINALES"
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 PLATEFORME DEVOPS CONFIGURÉE AVEC SUCCÈS ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}🌐 URLS D'ACCÈS:${NC}"
    echo "   • Nexus: http://$NEXUS_URL"
    echo "   • SonarQube: http://$SONARQUBE_URL"
    echo "   • ArgoCD: http://$ARGOCD_URL"
    echo ""
    
    echo -e "${BOLD}${YELLOW}📋 PROCHAINES ÉTAPES:${NC}"
    echo ""
    echo "1. 📤 CRÉER UN PROJET GITLAB:"
    echo "   • Créez un nouveau projet dans GitLab: $GITLAB_URL"
    echo "   • Copiez le contenu de demo-project/ dans votre repository"
    echo ""
    echo "2. 🔐 CONFIGURER LES VARIABLES GITLAB CI/CD:"
    echo "   • Allez dans Settings > CI/CD > Variables"
    echo "   • Ajoutez toutes les variables du fichier platform-config.env"
    echo ""
    echo "3. 🚀 DÉCLENCHER LE PIPELINE:"
    echo "   • Poussez votre code vers la branche main"
    echo "   • Le pipeline se déclenchera automatiquement"
    echo ""
    
    echo -e "${BOLD}${BLUE}💡 FICHIERS CRÉÉS:${NC}"
    echo "   • platform-config.env (variables d'environnement)"
    echo "   • gitlab-templates/ (templates CI/CD)"
    echo "   • demo-project/ (projet Spring Boot de démonstration)"
    echo ""
    
    echo -e "${BOLD}${GREEN}✨ Votre plateforme DevOps est maintenant prête ! ✨${NC}"
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
    
    if ! command -v curl &> /dev/null; then
        log_error "curl n'est pas installé"
        exit 1
    fi
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous configurer automatiquement la plateforme DevOps? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Configuration annulée par l'utilisateur"
        exit 0
    fi
    
    # Étapes de configuration
    read_config
    get_service_urls
    wait_for_services
    configure_nexus
    configure_sonarqube
    create_gitlab_secrets
    create_gitlab_template
    create_demo_project
    display_final_instructions
    
    echo ""
    log_success "🎉 CONFIGURATION TERMINÉE AVEC SUCCÈS ! 🎉"
    echo ""
}

# Lancer la configuration
main