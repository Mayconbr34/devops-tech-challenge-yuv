#!/bin/bash
# ===========================================
# Jimi IoT Gateway - Setup & Start Script
# Compatível com múltiplas distribuições e configurações
# ===========================================

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}       Jimi IoT Gateway - Setup & Start Script              ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Diretório do projeto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Carregar variáveis do .env (se existir)
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    . "$SCRIPT_DIR/.env"
    set +a
fi

STACK_MODE="${STACK_MODE:-local}"
if [ "$STACK_MODE" = "iothub" ]; then
    COMPOSE_FILE="$SCRIPT_DIR/iothub/docker-compose.yml"
    log_warn "STACK_MODE=iothub: usando a stack fornecida em iothub/ (sem gateway/observabilidade)."
else
    COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
fi

if [ "$STACK_MODE" != "iothub" ] && [ -z "${WEBHOOK_TOKEN:-}" ]; then
    log_warn "WEBHOOK_TOKEN não definido no .env. Webhooks serão rejeitados."
fi

# ===========================================
# Funções auxiliares
# ===========================================

check_root() {
    if [ "$EUID" -eq 0 ]; then
        log_warn "Executando como root. Algumas operações docker podem precisar de ajustes."
        SUDO=""
    else
        SUDO="sudo"
    fi
}

detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_UPDATE="$SUDO apt-get update -qq"
        PKG_INSTALL="$SUDO apt-get install -y -qq"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="$SUDO dnf check-update -q || true"
        PKG_INSTALL="$SUDO dnf install -y -q"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_UPDATE="$SUDO yum check-update -q || true"
        PKG_INSTALL="$SUDO yum install -y -q"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_UPDATE="$SUDO pacman -Sy --noconfirm"
        PKG_INSTALL="$SUDO pacman -S --noconfirm"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_UPDATE="$SUDO zypper refresh -q"
        PKG_INSTALL="$SUDO zypper install -y -q"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
        PKG_UPDATE="$SUDO apk update -q"
        PKG_INSTALL="$SUDO apk add -q"
    elif command -v brew &> /dev/null; then
        PKG_MANAGER="brew"
        PKG_UPDATE="brew update"
        PKG_INSTALL="brew install"
        SUDO=""
    else
        PKG_MANAGER="unknown"
    fi
}

install_docker() {
    log_info "Tentando instalar Docker..."
    
    case $PKG_MANAGER in
        apt)
            $PKG_UPDATE
            $PKG_INSTALL ca-certificates curl gnupg lsb-release
            
            # Tentar instalar docker.io (mais simples)
            if $PKG_INSTALL docker.io docker-compose; then
                log_success "Docker instalado via docker.io"
                return 0
            fi
            
            # Fallback: repositório oficial do Docker
            $SUDO install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            $SUDO chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true
            
            CODENAME=$(lsb_release -cs 2>/dev/null || echo "focal")
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            $SUDO apt-get update -qq
            $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || \
            $SUDO apt-get install -y docker.io docker-compose
            ;;
        dnf|yum)
            $SUDO $PKG_MANAGER install -y dnf-plugins-core 2>/dev/null || true
            $SUDO $PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || true
            $SUDO $PKG_MANAGER install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || \
            $SUDO $PKG_MANAGER install -y docker docker-compose
            ;;
        pacman)
            $PKG_INSTALL docker docker-compose
            ;;
        zypper)
            $PKG_INSTALL docker docker-compose
            ;;
        apk)
            $PKG_INSTALL docker docker-compose
            ;;
        brew)
            brew install --cask docker
            log_warn "Docker Desktop instalado. Por favor, inicie-o manualmente."
            ;;
        *)
            log_error "Não foi possível instalar Docker automaticamente."
            log_error "Por favor, instale manualmente: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac
}

start_docker_service() {
    # Verificar se systemd está disponível
    if command -v systemctl &> /dev/null; then
        # Verificar se o serviço está masked
        if systemctl is-enabled docker 2>&1 | grep -q "masked"; then
            log_warn "Docker service está masked. Tentando desmascarar..."
            $SUDO systemctl unmask docker.service 2>/dev/null || true
            $SUDO systemctl unmask docker.socket 2>/dev/null || true
        fi
        
        # Tentar iniciar o serviço
        if ! systemctl is-active --quiet docker 2>/dev/null; then
            log_info "Iniciando Docker service..."
            $SUDO systemctl start docker 2>/dev/null || \
            $SUDO systemctl start docker.socket 2>/dev/null || \
            $SUDO service docker start 2>/dev/null || true
            
            $SUDO systemctl enable docker 2>/dev/null || true
        fi
    elif command -v service &> /dev/null; then
        # Fallback para sistemas sem systemd
        $SUDO service docker start 2>/dev/null || true
    elif command -v rc-service &> /dev/null; then
        # OpenRC (Alpine, Gentoo)
        $SUDO rc-service docker start 2>/dev/null || true
    fi
    
    # Verificar se Docker está rodando
    sleep 2
    if docker info &>/dev/null; then
        return 0
    fi
    
    # Última tentativa: iniciar dockerd diretamente
    if ! pgrep -x dockerd &>/dev/null; then
        log_warn "Tentando iniciar dockerd diretamente..."
        $SUDO dockerd &>/dev/null &
        sleep 5
    fi
    
    # Verificação final
    if docker info &>/dev/null; then
        return 0
    else
        return 1
    fi
}

setup_docker_permissions() {
    # Verificar se usuário pode usar docker
    if ! docker info &>/dev/null; then
        if [ -S /var/run/docker.sock ]; then
            # Adicionar usuário ao grupo docker
            if getent group docker &>/dev/null; then
                $SUDO usermod -aG docker "$USER" 2>/dev/null || true
                log_warn "Usuário adicionado ao grupo docker."
                log_warn "Execute 'newgrp docker' ou faça logout/login para aplicar."
            fi
            
            # Ajustar permissões do socket temporariamente
            $SUDO chmod 666 /var/run/docker.sock 2>/dev/null || true
        fi
    fi
}

detect_docker_compose() {
    # Testar diferentes formas de chamar docker-compose
    if docker compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
        COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
    elif docker-compose --version &>/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
        COMPOSE_VERSION=$(docker-compose --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo "unknown")
    elif command -v podman-compose &>/dev/null; then
        DOCKER_COMPOSE="podman-compose"
        COMPOSE_VERSION=$(podman-compose --version 2>/dev/null || echo "unknown")
    else
        return 1
    fi
    return 0
}

# ===========================================
# INÍCIO DO SCRIPT
# ===========================================

check_root
detect_pkg_manager

# ===========================================
# 1. Verificar/Instalar Dependências
# ===========================================
echo -e "${YELLOW}[1/6]${NC} Verificando dependências..."

# Docker
if ! command -v docker &>/dev/null; then
    log_warn "Docker não encontrado. Instalando..."
    install_docker
fi

if command -v docker &>/dev/null; then
    log_success "Docker instalado"
else
    log_error "Falha ao instalar Docker. Instale manualmente."
    exit 1
fi

# Docker Compose
if ! detect_docker_compose; then
    log_warn "Docker Compose não encontrado. Instalando..."
    case $PKG_MANAGER in
        apt) $PKG_INSTALL docker-compose ;;
        dnf|yum) $PKG_INSTALL docker-compose ;;
        pacman) $PKG_INSTALL docker-compose ;;
        *) 
            # Instalar via pip como fallback
            if command -v pip3 &>/dev/null; then
                pip3 install docker-compose --user
            elif command -v pip &>/dev/null; then
                pip install docker-compose --user
            fi
            ;;
    esac
    detect_docker_compose
fi

if [ -n "$DOCKER_COMPOSE" ]; then
    log_success "Docker Compose disponível ($COMPOSE_VERSION)"
    DOCKER_COMPOSE="$DOCKER_COMPOSE -f $COMPOSE_FILE"
    log_info "Usando compose file: $COMPOSE_FILE"
else
    log_error "Docker Compose não disponível"
    exit 1
fi

# OpenSSL
if ! command -v openssl &>/dev/null; then
    log_warn "OpenSSL não encontrado. Instalando..."
    $PKG_INSTALL openssl 2>/dev/null || true
fi
command -v openssl &>/dev/null && log_success "OpenSSL instalado" || log_warn "OpenSSL não disponível (certificados podem falhar)"

# curl
if ! command -v curl &>/dev/null; then
    log_warn "curl não encontrado. Instalando..."
    $PKG_INSTALL curl 2>/dev/null || true
fi
command -v curl &>/dev/null && log_success "curl instalado" || log_warn "curl não disponível"

# jq (opcional)
if ! command -v jq &>/dev/null; then
    $PKG_INSTALL jq 2>/dev/null || true
fi

# ===========================================
# 2. Iniciar serviço Docker
# ===========================================
echo ""
echo -e "${YELLOW}[2/6]${NC} Verificando serviço Docker..."

if ! docker info &>/dev/null; then
    start_docker_service
    setup_docker_permissions
fi

# Verificação final do Docker
if docker info &>/dev/null; then
    log_success "Docker está rodando"
else
    log_error "Docker não está funcionando."
    echo ""
    echo "Possíveis soluções:"
    echo "  1. $SUDO systemctl unmask docker && $SUDO systemctl start docker"
    echo "  2. $SUDO service docker start"
    echo "  3. Reinicie o computador e tente novamente"
    echo "  4. Se usando Docker Desktop, inicie-o manualmente"
    echo ""
    echo "Após iniciar o Docker, execute este script novamente."
    exit 1
fi

# ===========================================
# 3. Configurar /etc/hosts
# ===========================================
echo ""
echo -e "${YELLOW}[3/6]${NC} Configurando /etc/hosts..."

if grep -q "api.jimi.local" /etc/hosts 2>/dev/null; then
    log_success "Entrada já existe em /etc/hosts"
else
    if echo "127.0.0.1 api.jimi.local" | $SUDO tee -a /etc/hosts > /dev/null 2>&1; then
        log_success "Entrada adicionada: 127.0.0.1 api.jimi.local"
    else
        log_warn "Não foi possível editar /etc/hosts automaticamente"
        echo "   Adicione manualmente: 127.0.0.1 api.jimi.local"
    fi
fi

# ===========================================
# 4. Gerar certificados TLS
# ===========================================
echo ""
echo -e "${YELLOW}[4/6]${NC} Gerando certificados TLS..."

CERTS_DIR="$SCRIPT_DIR/certs"
mkdir -p "$CERTS_DIR"

if [ -f "$CERTS_DIR/server.crt" ] && [ -f "$CERTS_DIR/server.key" ]; then
    log_success "Certificados já existem"
else
    if command -v openssl &>/dev/null; then
        # Gerar certificados inline (não depende do script externo)
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERTS_DIR/server.key" \
            -out "$CERTS_DIR/server.crt" \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=JimiIoT/CN=api.jimi.local" \
            -addext "subjectAltName=DNS:api.jimi.local,DNS:localhost,IP:127.0.0.1" \
            2>/dev/null
        
        if [ -f "$CERTS_DIR/server.crt" ]; then
            log_success "Certificados TLS gerados"
        else
            log_warn "Falha ao gerar certificados. HTTPS pode não funcionar."
        fi
    else
        log_warn "OpenSSL não disponível. Certificados não gerados."
    fi
fi

# ===========================================
# 5. Build das imagens
# ===========================================
echo ""
echo -e "${YELLOW}[5/6]${NC} Construindo imagens Docker..."

# Criar diretório de logs do nginx se não existir
mkdir -p "$SCRIPT_DIR/nginx/logs"

# Build
if $DOCKER_COMPOSE build 2>&1 | tee /tmp/docker-build.log | grep -E "(error|Error|ERROR)" ; then
    log_warn "Houve avisos durante o build. Verificando..."
fi

if $DOCKER_COMPOSE build --quiet 2>/dev/null || $DOCKER_COMPOSE build 2>/dev/null; then
    log_success "Imagens construídas"
else
    log_error "Falha no build das imagens"
    echo "   Verifique: cat /tmp/docker-build.log"
    exit 1
fi

# ===========================================
# 6. Iniciar stack
# ===========================================
echo ""
echo -e "${YELLOW}[6/6]${NC} Iniciando stack..."

# Parar containers antigos se existirem
$DOCKER_COMPOSE down 2>/dev/null || true

# Iniciar
if $DOCKER_COMPOSE up -d 2>&1; then
    log_success "Containers iniciados"
else
    log_error "Falha ao iniciar containers"
    $DOCKER_COMPOSE logs --tail=20
    exit 1
fi

# Aguardar containers ficarem prontos
echo ""
if [ "$STACK_MODE" = "iothub" ]; then
    log_warn "STACK_MODE=iothub: pulando healthcheck do gateway."
    BACKEND_OK=false
else
    log_info "Aguardando serviços ficarem prontos..."
    
    MAX_WAIT=120
    WAITED=0
    BACKEND_OK=false
    
    while [ $WAITED -lt $MAX_WAIT ]; do
        # Tentar diferentes formas de verificar
        if curl -sk --max-time 3 https://api.jimi.local/health 2>/dev/null | grep -q "healthy"; then
            BACKEND_OK=true
            break
        elif curl -sk --max-time 3 https://localhost/health 2>/dev/null | grep -q "healthy"; then
            BACKEND_OK=true
            break
        elif curl -s --max-time 3 http://localhost:8000/health 2>/dev/null | grep -q "healthy"; then
            BACKEND_OK=true
            break
        fi
        
        RUNNING=$($DOCKER_COMPOSE ps 2>/dev/null | grep -c "Up" || echo "?")
        printf "\r   Containers rodando: %s | Aguardando API... %ds   " "$RUNNING" "$WAITED"
        sleep 3
        WAITED=$((WAITED + 3))
    done
    echo ""
fi

# ===========================================
# Verificação Final
# ===========================================
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    Setup Concluído!                        ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""

echo "📦 Status dos containers:"
$DOCKER_COMPOSE ps
echo ""

echo "🔗 URLs de Acesso:"
if [ "$STACK_MODE" = "iothub" ]; then
    echo "   Stack iothub: consulte iothub/docker-compose.yml para portas"
else
    echo "   API Gateway:   https://api.jimi.local (ou https://localhost)"
    echo "   Observabilidade: não exposta no host por padrão"
fi
echo ""

if [ "$STACK_MODE" != "iothub" ] && [ "$BACKEND_OK" = true ]; then
    log_success "API está respondendo!"
    
    echo ""
    echo "🧪 Teste rápido:"
    RESPONSE=$(curl -sk -X POST https://api.jimi.local/v1/telemetry \
        -H "Content-Type: application/json" \
        -H "X-Jimi-Token: ${WEBHOOK_TOKEN:-}" \
        -d '{"device_id":"SETUP-TEST","timestamp":"2025-02-06T12:00:00Z","latitude":-23.55,"longitude":-46.63}' 2>/dev/null)
    
    if echo "$RESPONSE" | grep -q "ok"; then
        log_success "POST /v1/telemetry funcionando!"
        echo "   Response: $RESPONSE"
    else
        log_warn "Teste de telemetry retornou: $RESPONSE"
    fi
elif [ "$STACK_MODE" != "iothub" ]; then
    log_warn "API ainda inicializando ou não acessível via HTTPS"
    echo ""
    echo "Aguarde mais alguns segundos e teste manualmente:"
    echo "   curl -k https://api.jimi.local/health"
    echo "   curl -k https://localhost/health"
    echo "   $DOCKER_COMPOSE exec backend curl -s http://localhost:8000/health"
fi

echo ""
echo "📋 Comandos úteis:"
echo "   $DOCKER_COMPOSE ps          # Status"
echo "   $DOCKER_COMPOSE logs -f     # Logs em tempo real"
echo "   $DOCKER_COMPOSE logs backend --tail=50  # Logs do backend"
echo "   $DOCKER_COMPOSE down        # Parar tudo"
echo "   $DOCKER_COMPOSE restart     # Reiniciar"
echo ""

# Verificar se há erros nos logs
ERRORS=$(
    $DOCKER_COMPOSE logs 2>&1 | \
    grep -iE "error|exception|failed" | \
    grep -vE "provisioning\.plugins|provisioning\.notifiers|provisioning\.alerting|Skipping finding plugins" | \
    wc -l | tr -d ' '
)
if [ "$ERRORS" -gt 5 ]; then
    log_warn "Detectados $ERRORS erros nos logs. Verifique com: $DOCKER_COMPOSE logs"
fi

exit 0
