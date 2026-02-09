#!/bin/bash
# ===========================================
# Script para gerar certificados TLS auto-assinados
# Jimi IoT Gateway
# ===========================================

set -e

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${1:-api.jimi.local}"
DAYS="${2:-365}"

echo "🔐 Gerando certificados TLS para: $DOMAIN"

# Gerar chave privada
openssl genrsa -out "$CERT_DIR/server.key" 2048

# Criar arquivo de configuração para SAN (Subject Alternative Names)
cat > "$CERT_DIR/openssl.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
x509_extensions = v3_req

[dn]
C = BR
ST = Sao Paulo
L = Sao Paulo
O = Jimi IoT
OU = DevOps
CN = $DOMAIN

[req_ext]
subjectAltName = @alt_names

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = localhost
DNS.3 = *.jimi.local
IP.1 = 127.0.0.1
EOF

# Gerar certificado auto-assinado
openssl req -new -x509 \
    -key "$CERT_DIR/server.key" \
    -out "$CERT_DIR/server.crt" \
    -days "$DAYS" \
    -config "$CERT_DIR/openssl.cnf"

# Verificar certificado
echo ""
echo "✅ Certificados gerados com sucesso!"
echo ""
openssl x509 -in "$CERT_DIR/server.crt" -text -noout | grep -A2 "Subject:"
echo ""
echo "📁 Arquivos gerados:"
echo "   - $CERT_DIR/server.key (chave privada)"
echo "   - $CERT_DIR/server.crt (certificado)"

# Limpar arquivo temporário
rm -f "$CERT_DIR/openssl.cnf"

echo ""
echo "🔧 Para confiar neste certificado localmente:"
echo "   sudo cp $CERT_DIR/server.crt /usr/local/share/ca-certificates/jimi-local.crt"
echo "   sudo update-ca-certificates"
