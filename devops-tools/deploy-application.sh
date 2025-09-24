#!/bin/bash

# =============================================================================
# SCRIPT DE DÉPLOIEMENT AUTOMATIQUE D'APPLICATION
# Fichier: deploy-application.sh
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
    echo -e "    🚀 DÉPLOIEMENT AUTOMATIQUE D'APPLICATION"
    echo -e "    📦 Pipeline CI/CD Complet"
    echo -e "    🔄 GitLab → SonarQube → Nexus → ArgoCD"
    echo -e "================================================${NC}"
    echo ""
}

# Variables globales
APP_NAME=""
GITLAB_PROJECT_URL=""
BRANCH="main"

# Fonction pour lire les paramètres
read_parameters() {
    log_step "📝 CONFIGURATION DU DÉPLOIEMENT"
    
    # Nom de l'application
    if [ -z "$APP_NAME" ]; then
        read -p "Nom de l'application: " APP_NAME
    fi
    
    # URL du projet GitLab
    if [ -z "$GITLAB_PROJECT_URL" ]; then
        read -p "URL du projet GitLab (ex: http://gitlab.com/user/project.git): " GITLAB_PROJECT_URL
    fi
    
    # Branche (optionnel)
    read -p "Branche à déployer (défaut: main): " INPUT_BRANCH
    if [ -n "$INPUT_BRANCH" ]; then
        BRANCH="$INPUT_BRANCH"
    fi
    
    log_success "✅ Configuration:"
    log_info "   - Application: $APP_NAME"
    log_info "   - Projet GitLab: $GITLAB_PROJECT_URL"
    log_info "   - Branche: $BRANCH"
}

# Lire la configuration de la plateforme
read_platform_config() {
    log_step "🔧 LECTURE DE LA CONFIGURATION PLATEFORME"
    
    if [ ! -f "platform-config.env" ]; then
        log_error "Fichier platform-config.env non trouvé"
        log_info "Exécutez d'abord: ./configure-devops-platform.sh"
        exit 1
    fi
    
    source platform-config.env
    
    log_success "✅ Configuration plateforme chargée"
    log_info "   - Nexus: $NEXUS_URL"
    log_info "   - SonarQube: $SONARQUBE_URL"
    log_info "   - ArgoCD: $ARGOCD_URL"
}

# Créer l'application ArgoCD
create_argocd_application() {
    log_step "🎯 CRÉATION DE L'APPLICATION ARGOCD"
    
    log_info "Création de l'application $APP_NAME dans ArgoCD..."
    
    # Créer le namespace pour l'application
    kubectl create namespace $APP_NAME --dry-run=client -o yaml | kubectl apply -f -
    
    # Créer l'application ArgoCD
    cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_NAME
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $GITLAB_PROJECT_URL
    targetRevision: $BRANCH
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: $APP_NAME
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true
  revisionHistoryLimit: 3
EOF
    
    log_success "✅ Application $APP_NAME créée dans ArgoCD"
}

# Créer un projet SonarQube
create_sonarqube_project() {
    log_step "🔍 CRÉATION DU PROJET SONARQUBE"
    
    log_info "Création du projet $APP_NAME dans SonarQube..."
    
    # Créer le projet via API SonarQube
    curl -s -u admin:$SONARQUBE_PASSWORD -X POST "$SONARQUBE_URL/api/projects/create" \
        -d "name=$APP_NAME" \
        -d "project=$APP_NAME" \
        -d "visibility=public" || log_warning "Projet SonarQube existe peut-être déjà"
    
    # Créer un token spécifique pour ce projet
    PROJECT_TOKEN=$(curl -s -u admin:$SONARQUBE_PASSWORD -X POST "$SONARQUBE_URL/api/user_tokens/generate" \
        -d "name=$APP_NAME-token" | jq -r '.token' 2>/dev/null || echo "")
    
    if [ -n "$PROJECT_TOKEN" ]; then
        log_success "✅ Token SonarQube créé pour $APP_NAME"
        echo "SONAR_TOKEN_$APP_NAME=$PROJECT_TOKEN" >> platform-config.env
    fi
    
    log_success "✅ Projet SonarQube configuré"
}

# Configurer le registry Docker dans Nexus
configure_docker_registry() {
    log_step "🐳 CONFIGURATION DU REGISTRY DOCKER"
    
    log_info "Configuration du registry Docker pour $APP_NAME..."
    
    # Vérifier que le registry Docker existe
    REGISTRY_EXISTS=$(curl -s -u admin:$NEXUS_PASSWORD "$NEXUS_URL/service/rest/v1/repositories" | \
        jq -r '.[] | select(.name=="docker-private") | .name' || echo "")
    
    if [ "$REGISTRY_EXISTS" != "docker-private" ]; then
        log_info "Création du registry Docker..."
        curl -s -u admin:$NEXUS_PASSWORD -X POST "$NEXUS_URL/service/rest/v1/repositories/docker/hosted" \
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
                    "httpPort": 8082
                }
            }'
    fi
    
    log_success "✅ Registry Docker configuré"
}

# Générer les manifestes Kubernetes pour l'application
generate_k8s_manifests() {
    log_step "📦 GÉNÉRATION DES MANIFESTES KUBERNETES"
    
    log_info "Génération des manifestes pour $APP_NAME..."
    
    mkdir -p app-manifests/$APP_NAME/k8s
    
    # Deployment
    cat > app-manifests/$APP_NAME/k8s/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $APP_NAME
  namespace: $APP_NAME
  labels:
    app: $APP_NAME
    version: "1.0"
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
        version: "1.0"
    spec:
      containers:
      - name: $APP_NAME
        image: $DOCKER_REGISTRY/$APP_NAME:latest
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: SPRING_PROFILES_ACTIVE
          value: "production"
        - name: APP_NAME
          value: "$APP_NAME"
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 10
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
      imagePullSecrets:
      - name: nexus-registry-secret
EOF

    # Service
    cat > app-manifests/$APP_NAME/k8s/service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME-service
  namespace: $APP_NAME
  labels:
    app: $APP_NAME
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
  selector:
    app: $APP_NAME
EOF

    # Ingress (optionnel)
    cat > app-manifests/$APP_NAME/k8s/ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $APP_NAME-ingress
  namespace: $APP_NAME
  annotations:
    kubernetes.io/ingress.class: "alb"
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - host: $APP_NAME.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $APP_NAME-service
            port:
              number: 80
EOF

    # ConfigMap pour la configuration
    cat > app-manifests/$APP_NAME/k8s/configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $APP_NAME-config
  namespace: $APP_NAME
data:
  application.yml: |
    server:
      port: 8080
    management:
      endpoints:
        web:
          exposure:
            include: health,info,metrics
      endpoint:
        health:
          show-details: always
    logging:
      level:
        com.$APP_NAME: INFO
        org.springframework: WARN
EOF

    # Secret pour accéder au registry Nexus
    kubectl create secret docker-registry nexus-registry-secret \
        --docker-server=$DOCKER_REGISTRY \
        --docker-username=$NEXUS_USERNAME \
        --docker-password=$NEXUS_PASSWORD \
        --namespace=$APP_NAME \
        --dry-run=client -o yaml > app-manifests/$APP_NAME/k8s/registry-secret.yaml
    
    log_success "✅ Manifestes Kubernetes générés dans app-manifests/$APP_NAME/k8s/"
}

# Générer le fichier GitLab CI/CD pour l'application
generate_gitlab_ci() {
    log_step "🔄 GÉNÉRATION DU PIPELINE GITLAB CI/CD"
    
    log_info "Génération du .gitlab-ci.yml pour $APP_NAME..."
    
    cat > app-manifests/$APP_NAME/.gitlab-ci.yml << EOF
# Pipeline CI/CD pour $APP_NAME
# Généré automatiquement par deploy-application.sh

variables:
  DOCKER_DRIVER: overlay2
  DOCKER_TLS_CERTDIR: "/certs"
  MAVEN_OPTS: "-Dmaven.repo.local=.m2/repository"
  APP_NAME: "$APP_NAME"
  DOCKER_IMAGE: "\$DOCKER_REGISTRY/\$APP_NAME"

stages:
  - build
  - test
  - security
  - package
  - deploy

# Cache pour Maven
cache:
  paths:
    - .m2/repository/

# Build l'application
build:
  stage: build
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Building \$APP_NAME..."
    - mvn clean compile -DskipTests
  artifacts:
    paths:
      - target/
    expire_in: 1 hour
  only:
    - main
    - develop
    - merge_requests

# Tests unitaires
test:
  stage: test
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Running tests for \$APP_NAME..."
    - mvn test
  artifacts:
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml
      coverage_report:
        coverage_format: jacoco
        path: target/site/jacoco/jacoco.xml
  coverage: '/Total.*?([0-9]{1,3})%/'
  only:
    - main
    - develop
    - merge_requests

# Analyse de sécurité avec SonarQube
security_scan:
  stage: security
  image: maven:3.8.6-openjdk-11
  script:
    - echo "Running SonarQube analysis for \$APP_NAME..."
    - mvn sonar:sonar
        -Dsonar.host.url=\$SONARQUBE_URL
        -Dsonar.login=\$SONAR_TOKEN
        -Dsonar.projectKey=\$APP_NAME
        -Dsonar.projectName=\$APP_NAME
        -Dsonar.sources=src/main/java
        -Dsonar.tests=src/test/java
        -Dsonar.java.binaries=target/classes
        -Dsonar.junit.reportPaths=target/surefire-reports
        -Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
  allow_failure: false
  only:
    - main
    - develop

# Build et push de l'image Docker
package:
  stage: package
  image: docker:20.10.16
  services:
    - docker:20.10.16-dind
  before_script:
    - echo \$NEXUS_PASSWORD | docker login \$DOCKER_REGISTRY -u \$NEXUS_USERNAME --password-stdin
  script:
    - echo "Building Docker image for \$APP_NAME..."
    - mvn package -DskipTests
    - docker build -t \$DOCKER_IMAGE:\$CI_COMMIT_SHA .
    - docker build -t \$DOCKER_IMAGE:latest .
    - echo "Pushing Docker image to Nexus registry..."
    - docker push \$DOCKER_IMAGE:\$CI_COMMIT_SHA
    - docker push \$DOCKER_IMAGE:latest
    - echo "Image pushed: \$DOCKER_IMAGE:latest"
  only:
    - main

# Déploiement via ArgoCD
deploy:
  stage: deploy
  image: argoproj/argocd:v2.8.4
  before_script:
    - echo "Connecting to ArgoCD..."
    - argocd login \$ARGOCD_URL --username \$ARGOCD_USERNAME --password \$ARGOCD_PASSWORD --insecure
  script:
    - echo "Deploying \$APP_NAME via ArgoCD..."
    - argocd app sync \$APP_NAME --force
    - echo "Waiting for deployment to be healthy..."
    - argocd app wait \$APP_NAME --health --timeout 300
    - echo "Getting application status..."
    - argocd app get \$APP_NAME
  environment:
    name: production
    url: http://\$APP_NAME.\$APP_NAME.svc.cluster.local
  only:
    - main

# Job de notification (optionnel)
notify:
  stage: deploy
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
  script:
    - echo "Deployment completed for \$APP_NAME"
    - echo "Application URL: http://\$APP_NAME.\$APP_NAME.svc.cluster.local"
    - echo "ArgoCD URL: \$ARGOCD_URL"
  when: on_success
  only:
    - main
EOF

    log_success "✅ Pipeline GitLab CI/CD généré"
}

# Générer le Dockerfile pour l'application
generate_dockerfile() {
    log_step "🐳 GÉNÉRATION DU DOCKERFILE"
    
    log_info "Génération du Dockerfile pour $APP_NAME..."
    
    cat > app-manifests/$APP_NAME/Dockerfile << EOF
# Dockerfile pour $APP_NAME
# Build stage
FROM maven:3.8.6-openjdk-11 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn clean package -DskipTests

# Runtime stage
FROM openjdk:11-jre-slim
WORKDIR /app

# Créer un utilisateur non-root
RUN groupadd -r appuser && useradd -r -g appuser appuser

# Installer curl pour les health checks
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Copier l'application
COPY --from=builder /app/target/*.jar app.jar

# Changer les permissions
RUN chown appuser:appuser app.jar

# Utiliser l'utilisateur non-root
USER appuser

# Variables d'environnement
ENV JAVA_OPTS="-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"
ENV SPRING_PROFILES_ACTIVE=production

# Port d'exposition
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1

# Point d'entrée
ENTRYPOINT ["sh", "-c", "java \$JAVA_OPTS -jar app.jar"]
EOF

    log_success "✅ Dockerfile généré"
}

# Créer un exemple d'application Spring Boot
generate_spring_boot_app() {
    log_step "🏗️ GÉNÉRATION DE L'APPLICATION SPRING BOOT"
    
    log_info "Génération d'une application Spring Boot pour $APP_NAME..."
    
    mkdir -p app-manifests/$APP_NAME/src/main/java/com/devops/$APP_NAME
    mkdir -p app-manifests/$APP_NAME/src/test/java/com/devops/$APP_NAME
    mkdir -p app-manifests/$APP_NAME/src/main/resources
    
    # Application principale
    cat > app-manifests/$APP_NAME/src/main/java/com/devops/$APP_NAME/Application.java << EOF
package com.devops.$APP_NAME;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.beans.factory.annotation.Value;

@SpringBootApplication
@RestController
public class Application {
    
    @Value("\${app.version:1.0.0}")
    private String version;
    
    @Value("\${app.name:$APP_NAME}")
    private String appName;
    
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
    
    @GetMapping("/")
    public String home() {
        return String.format("Welcome to %s v%s! 🚀", appName, version);
    }
    
    @GetMapping("/info")
    public Object info() {
        return new java.util.HashMap<String, Object>() {{
            put("name", appName);
            put("version", version);
            put("status", "running");
            put("timestamp", new java.util.Date());
            put("message", "Application deployed via DevOps Platform CI/CD!");
        }};
    }
    
    @GetMapping("/health")
    public Object health() {
        return new java.util.HashMap<String, String>() {{
            put("status", "UP");
            put("application", appName);
        }};
    }
}
EOF

    # Test
    cat > app-manifests/$APP_NAME/src/test/java/com/devops/$APP_NAME/ApplicationTest.java << EOF
package com.devops.$APP_NAME;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringBootTest
@SpringJUnitConfig
class ApplicationTest {
    
    @Test
    void contextLoads() {
        // Test que l'application démarre correctement
    }
}
EOF

    # Configuration
    cat > app-manifests/$APP_NAME/src/main/resources/application.yml << EOF
# Configuration pour $APP_NAME
server:
  port: 8080
  servlet:
    context-path: /

app:
  name: $APP_NAME
  version: 1.0.0

management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  endpoint:
    health:
      show-details: always
  metrics:
    export:
      prometheus:
        enabled: true

logging:
  level:
    com.devops.$APP_NAME: INFO
    org.springframework: WARN
  pattern:
    console: "%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n"

---
spring:
  profiles: production
  
logging:
  level:
    root: WARN
    com.devops.$APP_NAME: INFO
EOF

    # POM.xml
    cat > app-manifests/$APP_NAME/pom.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 
         http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    
    <groupId>com.devops</groupId>
    <artifactId>$APP_NAME</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>
    
    <name>$APP_NAME</name>
    <description>Application $APP_NAME deployée via pipeline DevOps</description>
    
    <parent>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-parent</artifactId>
        <version>2.7.14</version>
        <relativePath/>
    </parent>
    
    <properties>
        <java.version>11</java.version>
        <maven.compiler.source>11</maven.compiler.source>
        <maven.compiler.target>11</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
        <sonar.organization>devops</sonar.organization>
        <sonar.coverage.jacoco.xmlReportPaths>target/site/jacoco/jacoco.xml</sonar.coverage.jacoco.xmlReportPaths>
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
            <groupId>io.micrometer</groupId>
            <artifactId>micrometer-registry-prometheus</artifactId>
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
                <configuration>
                    <excludes>
                        <exclude>
                            <groupId>org.projectlombok</groupId>
                            <artifactId>lombok</artifactId>
                        </exclude>
                    </excludes>
                </configuration>
            </plugin>
            
            <plugin>
                <groupId>org.sonarsource.scanner.maven</groupId>
                <artifactId>sonar-maven-plugin</artifactId>
                <version>3.9.1.2184</version>
            </plugin>
            
            <plugin>
                <groupId>org.jacoco</groupId>
                <artifactId>jacoco-maven-plugin</artifactId>
                <version>0.8.8</version>
                <executions>
                    <execution>
                        <goals>
                            <goal>prepare-agent</goal>
                        </goals>
                    </execution>
                    <execution>
                        <id>report</id>
                        <phase>test</phase>
                        <goals>
                            <goal>report</goal>
                        </goals>
                    </execution>
                </executions>
            </plugin>
        </plugins>
    </build>
</project>
EOF

    log_success "✅ Application Spring Boot générée"
}

# Déployer l'application dans ArgoCD
deploy_to_argocd() {
    log_step "🚀 DÉPLOIEMENT DANS ARGOCD"
    
    log_info "Déploiement de l'application dans le cluster..."
    
    # Appliquer les manifestes Kubernetes directement pour démarrer
    kubectl apply -f app-manifests/$APP_NAME/k8s/
    
    # Synchroniser avec ArgoCD
    if command -v argocd &> /dev/null; then
        log_info "Synchronisation avec ArgoCD..."
        argocd login $ARGOCD_URL --username $ARGOCD_USERNAME --password $ARGOCD_PASSWORD --insecure
        argocd app sync $APP_NAME --force
        argocd app wait $APP_NAME --health --timeout 300
    fi
    
    log_success "✅ Application déployée avec succès"
}

# Vérifier le déploiement
verify_deployment() {
    log_step "✅ VÉRIFICATION DU DÉPLOIEMENT"
    
    log_info "Vérification de l'état de l'application..."
    
    # Attendre que les pods soient prêts
    kubectl wait --for=condition=ready pod -l app=$APP_NAME -n $APP_NAME --timeout=300s
    
    # Afficher l'état
    echo ""
    echo "État des pods:"
    kubectl get pods -n $APP_NAME
    
    echo ""
    echo "État des services:"
    kubectl get svc -n $APP_NAME
    
    # Test de connectivité
    log_info "Test de connectivité..."
    if kubectl get pods -l app=$APP_NAME -n $APP_NAME | grep -q Running; then
        # Port-forward pour tester
        kubectl port-forward svc/$APP_NAME-service 8080:80 -n $APP_NAME &
        PF_PID=$!
        sleep 5
        
        if curl -s http://localhost:8080/ > /dev/null; then
            log_success "✅ Application accessible et fonctionnelle!"
        else
            log_warning "⚠️ Application déployée mais pas encore accessible"
        fi
        
        kill $PF_PID 2>/dev/null || true
    fi
    
    log_success "✅ Déploiement vérifié"
}

# Afficher les instructions finales
display_deployment_summary() {
    log_step "📋 RÉSUMÉ DU DÉPLOIEMENT"
    
    echo ""
    echo -e "${BOLD}${GREEN}🎉 APPLICATION $APP_NAME DÉPLOYÉE AVEC SUCCÈS ! 🎉${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}📦 FICHIERS GÉNÉRÉS:${NC}"
    echo "   • app-manifests/$APP_NAME/"
    echo "     ├── src/ (Code Spring Boot)"
    echo "     ├── k8s/ (Manifestes Kubernetes)" 
    echo "     ├── .gitlab-ci.yml (Pipeline CI/CD)"
    echo "     ├── Dockerfile (Image Docker)"
    echo "     └── pom.xml (Configuration Maven)"
    echo ""
    
    echo -e "${BOLD}${YELLOW}🔄 PIPELINE CI/CD:${NC}"
    echo "   1. 📤 Poussez le code vers GitLab: $GITLAB_PROJECT_URL"
    echo "   2. 🔄 Le pipeline se déclenchera automatiquement"
    echo "   3. 🔍 SonarQube analysera le code"
    echo "   4. 📦 L'image sera construite et poussée vers Nexus"
    echo "   5. 🚀 ArgoCD déploiera automatiquement"
    echo ""
    
    echo -e "${BOLD}${BLUE}🌐 ACCÈS À L'APPLICATION:${NC}"
    echo "   • Locale: kubectl port-forward svc/$APP_NAME-service 8080:80 -n $APP_NAME"
    echo "   • ArgoCD: $ARGOCD_URL (voir l'application $APP_NAME)"
    echo "   • SonarQube: $SONARQUBE_URL (projet $APP_NAME)"
    echo "   • Nexus: $NEXUS_URL (registry docker-private)"
    echo ""
    
    echo -e "${BOLD}${PURPLE}📊 MONITORING:${NC}"
    echo "   • kubectl get pods -n $APP_NAME"
    echo "   • kubectl logs -l app=$APP_NAME -n $APP_NAME"
    echo "   • kubectl describe app $APP_NAME -n argocd"
    echo ""
    
    echo -e "${BOLD}${GREEN}✨ Votre application est maintenant dans le pipeline DevOps ! ✨${NC}"
    echo ""
}

# Fonction principale
main() {
    show_banner
    
    # Lire les paramètres
    read_parameters
    read_platform_config
    
    # Demander confirmation
    echo ""
    read -p "Voulez-vous déployer l'application $APP_NAME? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Déploiement annulé par l'utilisateur"
        exit 0
    fi
    
    # Étapes de déploiement
    create_argocd_application
    create_sonarqube_project  
    configure_docker_registry
    generate_k8s_manifests
    generate_gitlab_ci
    generate_dockerfile
    generate_spring_boot_app
    deploy_to_argocd
    verify_deployment
    display_deployment_summary
    
    echo ""
    log_success "🎉 DÉPLOIEMENT TERMINÉ AVEC SUCCÈS ! 🎉"
    echo ""
}

# Gestion des arguments
case "${1:-}" in
    "")
        main
        ;;
    "--app")
        APP_NAME="$2"
        GITLAB_PROJECT_URL="$3"
        main
        ;;
    "help")
        echo "Usage: $0 [--app APP_NAME GITLAB_URL]"
        echo "Déploie automatiquement une application dans la plateforme DevOps"
        ;;
    *)
        log_error "Argument invalide: $1"
        exit 1
        ;;
esac