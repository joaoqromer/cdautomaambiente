#!/usr/bin/env bash
set -euo pipefail

# Cores e funções utilitárias
say(){ echo -e "\n\033[1;34m==> $*\033[0m"; }
warn(){ echo -e "\033[1;33m⚠️  $*\033[0m"; }
error(){ echo -e "\033[1;31m❌ $*\033[0m"; }
success(){ echo -e "\033[1;32m✅ $*\033[0m"; }
info(){ echo -e "\033[1;36mℹ️  $*\033[0m"; }
ask(){ local v=$1 d=$2 m=$3; read -erp "$m [$d]: " a; printf -v "$v" '%s' "${a:-$d}"; }
ask_yn(){ local v=$1 d=$2 m=$3; [[ ${AUTO:-n} == y ]] && { printf -v "$v" y; return; }
  while read -erp "$m [$d]: " r; do r=${r:-$d}; r=${r,,}; [[ $r =~ ^y|n$ ]] && { printf -v "$v" "$r"; break; }; done; }
has(){ docker ps -a --format '{{.Names}}'|grep -q "^$1$"; }

# Configurações globais
NET=proxy
BASE_DIR=/opt
BACKUP_DIR=/root/backup

# Função para verificar e instalar dependências
install_dependencies() {
    say "🔧 Verificando dependências"
    apt-get update -y
    apt-get install -y apparmor-utils curl jq
    
    if ! command -v docker >/dev/null; then
        say "📦 Instalando Docker"
        curl -fsSL https://get.docker.com | sh
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        say "📦 Instalando Docker Compose"
        apt-get install -y docker-compose-plugin
    fi
    
    # Criar rede proxy se não existir
    if ! docker network ls --format '{{.Name}}' | grep -q "^$NET$"; then
        docker network create $NET
    fi
    
    # Criar diretório de backup
    mkdir -p "$BACKUP_DIR"
}

# Função para detectar Traefik existente
detect_existing_traefik() {
    local existing_traefiks=($(docker ps -a --format '{{.Names}}' | grep '^traefik_' || true))
    
    if [ ${#existing_traefiks[@]} -gt 0 ]; then
        echo "${existing_traefiks[0]}"
        return 0
    else
        echo ""
        return 1
    fi
}

# Função para analisar ambientes existentes
analyze_environments() {
    say "🔍 Analisando ambientes existentes"
    
    local environments=()
    local dirs=($(find $BASE_DIR -maxdepth 1 -type d -name "*" | grep -v "^$BASE_DIR$" | sort))
    
    echo -e "\n📊 RELATÓRIO DO SISTEMA:"
    echo "========================"
    
    # Detectar Traefik existente
    local existing_traefik=$(detect_existing_traefik || true)
    if [ -n "$existing_traefik" ]; then
        info "🚦 Traefik detectado: $existing_traefik (será reutilizado para novos ambientes)"
    else
        warn "🚦 Nenhum Traefik encontrado - será necessário instalar um"
    fi
    
    # Verificar diretórios de ambiente
    if [ ${#dirs[@]} -gt 0 ]; then
        echo -e "\n📁 Diretórios encontrados:"
        for dir in "${dirs[@]}"; do
            local env_name=$(basename "$dir")
            echo "   • $env_name"
            environments+=("$env_name")
        done
    else
        echo -e "\n📁 Nenhum diretório de ambiente encontrado"
    fi
    
    # Verificar containers por ambiente
    echo -e "\n🐳 Containers por ambiente:"
    local all_containers=$(docker ps -a --format "{{.Names}}" | sort)
    local env_containers=()
    
    # Agrupar containers por ambiente
    while IFS= read -r container; do
        if [[ $container =~ ^(traefik|portainer|n8n|evolution|redis)_(.+)$ ]]; then
            local service="${BASH_REMATCH[1]}"
            local env="${BASH_REMATCH[2]}"
            local status=$(docker ps --format "{{.Status}}" --filter name="^${container}$")
            
            # Armazenar informações do container
            env_containers+=("$env:$service:$container:$status")
        fi
    done <<< "$all_containers"
    
    # Exibir containers agrupados por ambiente
    local current_env=""
    for item in $(printf '%s\n' "${env_containers[@]}" | sort); do
        IFS=':' read -r env service container status <<< "$item"
        
        if [ "$env" != "$current_env" ]; then
            echo -e "\n   📦 Ambiente: $env"
            current_env="$env"
        fi
        
        local status_icon="❌"
        [[ $status =~ ^Up ]] && status_icon="✅"
        
        echo "      $status_icon $service ($container) - $status"
    done
    
    # Verificar volumes
    echo -e "\n💾 Volumes Docker:"
    local volumes=$(docker volume ls --format "{{.Name}}" | grep -E "(traefik_acme_|portainer_data_|n8n_.*_data|evol_.*_data)" | sort || true)
    if [ -n "$volumes" ]; then
        while IFS= read -r volume; do
            local size=$(docker system df -v | grep "$volume" | awk '{print $3}' || echo "N/A")
            echo "   💾 $volume ($size)"
        done <<< "$volumes"
    else
        echo "   Nenhum volume de ambiente encontrado"
    fi
    
    # Verificar rede
    echo -e "\n🌐 Rede Docker:"
    if docker network ls --format '{{.Name}}' | grep -q "^$NET$"; then
        local containers_in_network=$(docker network inspect $NET --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
        echo "   ✅ Rede '$NET' existe"
        if [ -n "$containers_in_network" ]; then
            echo "   🔗 Containers conectados: $containers_in_network"
        fi
    else
        echo "   ❌ Rede '$NET' não encontrada"
    fi
    
    # Verificar containers compartilhados
    echo -e "\n🔗 Serviços Compartilhados:"
    if has pg_shared; then
        local pg_status=$(docker ps --format "{{.Status}}" --filter name="^pg_shared$")
        echo "   ✅ PostgreSQL compartilhado - $pg_status"
        
        # Verificar schemas no PostgreSQL
        local schemas=$(docker exec pg_shared psql -U postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%_schema';" 2>/dev/null | tr -d ' ' | grep -v '^$' || true)
        if [ -n "$schemas" ]; then
            echo "   🗃️  Schemas encontrados:"
            while IFS= read -r schema; do
                echo "      • $schema"
            done <<< "$schemas"
        fi
    else
        echo "   ❌ PostgreSQL compartilhado não encontrado"
    fi
    
    # Retornar ambientes encontrados
    printf '%s\n' "${environments[@]}"
}

# Função para criar novo ambiente
create_environment() {
    say "🚀 Criando novo ambiente"
    
    # Detectar Traefik existente
    local existing_traefik=$(detect_existing_traefik || true)
    
    # Defaults
    local ENV="" DOMAIN="exemplo.com.br" EMAIL=""
    local SUB_T="" SUB_P="" SUB_N="" SUB_E=""
    local OFFSET=10 FORCE_T=""
    
    ask ENV "" "Nome do ambiente (ex: v2, prod, dev)"
    [ -z "$ENV" ] && { error "Nome do ambiente é obrigatório"; return 1; }
    
    # Verificar se ambiente já existe
    if [ -d "$BASE_DIR/$ENV" ]; then
        warn "Ambiente '$ENV' já existe!"
        ask_yn OVERWRITE n "Sobrescrever ambiente existente?"
        [ "$OVERWRITE" != "y" ] && return 1
    fi
    
    ask DOMAIN "$DOMAIN" "Domínio principal"
    EMAIL="admin@$DOMAIN"
    ask EMAIL "$EMAIL" "Email Let's Encrypt"
    
    SUB_T="traefik$ENV"
    SUB_P="portainer$ENV"
    SUB_N="n8n$ENV"
    SUB_E="evol$ENV"
    
    ask SUB_T "$SUB_T" "Subdomínio Traefik"
    ask SUB_P "$SUB_P" "Subdomínio Portainer"
    ask SUB_N "$SUB_N" "Subdomínio n8n"
    ask SUB_E "$SUB_E" "Subdomínio Evolution"
    ask OFFSET "$OFFSET" "Offset portas externas"
    
    # Decisão sobre Traefik baseada na detecção
    if [ -n "$existing_traefik" ]; then
        info "🚦 Traefik existente detectado: $existing_traefik"
        info "🔄 Reutilizando Traefik existente para o novo ambiente"
        FORCE_T="n"
    else
        ask FORCE_T "y" "Nenhum Traefik encontrado. Instalar Traefik? (y/n)"
    fi
    
    local DIR="$BASE_DIR/$ENV"
    mkdir -p "$DIR"
    
    # Hash bcrypt para admin:changeMe!
    local HASH='$2y$05$f0Bm1Ri7wFkVIkGdVUq/6.3/jbpTOyBp34g6fMk9TvqphrJ9Xrnu2'
    local LABEL_HASH="admin:$$${HASH#\$}"
    
    # Criar PostgreSQL compartilhado se não existir
    if ! has pg_shared; then
        say "🐘 Criando PostgreSQL compartilhado"
        docker run -d --name pg_shared --network $NET \
            -e POSTGRES_PASSWORD=postgrespass \
            -v pg_shared:/var/lib/postgresql/data \
            postgres:15-alpine
        sleep 5
    fi
    
    # 1. Traefik (apenas se necessário)
    local I_T="n"
    [[ $FORCE_T == "y" ]] && I_T="y"
    
    if [[ $I_T == y ]]; then
        say "🚦 Configurando Traefik ($ENV)"
        cat > "$DIR/traefik.yml" <<EOF
services:
  traefik:
    image: traefik:latest
    container_name: traefik_$ENV
    command:
      - --ping=true
      - --ping.entrypoint=web
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --providers.docker
      - --api.dashboard=true
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.le.acme.email=$EMAIL
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
    ports: ["80:80","443:443"]
    networks: [$NET]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_acme_$ENV:/acme
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik_$ENV.rule=Host(\`$SUB_T.$DOMAIN\`)
      - traefik.http.routers.traefik_$ENV.entrypoints=websecure
      - traefik.http.routers.traefik_$ENV.tls.certresolver=le
      - traefik.http.routers.traefik_$ENV.middlewares=auth-$ENV
      - traefik.http.routers.traefik_$ENV.service=api@internal
      - traefik.http.middlewares.auth-$ENV.basicauth.users=$LABEL_HASH
volumes: { traefik_acme_$ENV: {} }
networks: { $NET: { external: true } }
EOF
        docker compose -f "$DIR/traefik.yml" up -d
        until curl -fs http://localhost/ping >/dev/null 2>&1; do sleep 2; done
    fi
    
    # 2. Portainer
    if ! has portainer_$ENV; then
        ask_yn P y "Criar Portainer ($ENV)?"
        if [[ $P == y ]]; then
            say "📊 Configurando Portainer ($ENV)"
            docker run -d --name portainer_$ENV --network $NET \
                -v /var/run/docker.sock:/var/run/docker.sock \
                -v portainer_data_$ENV:/data \
                -l traefik.enable=true \
                -l traefik.http.routers.portainer_$ENV.rule=Host\(\`$SUB_P.$DOMAIN\`\) \
                -l traefik.http.routers.portainer_$ENV.entrypoints=websecure \
                -l traefik.http.routers.portainer_$ENV.tls.certresolver=le \
                -l traefik.http.services.portainer_$ENV.loadbalancer.server.port=9000 \
                portainer/portainer-ce:latest
        fi
    fi
    
    # 3. Redis
    if ! has redis_$ENV; then
        ask_yn R y "Criar Redis ($ENV)?"
        if [[ $R == y ]]; then
            say "🔴 Configurando Redis ($ENV)"
            docker run -d --name redis_$ENV --network $NET redis:7-alpine
        fi
    fi
    
    # 4. n8n
    if ! has n8n_$ENV; then
        ask_yn N y "Criar n8n ($ENV)?"
        if [[ $N == y ]]; then
            say "🔄 Configurando n8n ($ENV)"
            docker run -d --name n8n_$ENV --network $NET \
                -e QUEUE_MODE=true \
                -e EXECUTIONS_PROCESS=main \
                -e DB_TYPE=postgresdb \
                -e DB_POSTGRESDB_HOST=pg_shared \
                -e DB_POSTGRESDB_DATABASE=postgres \
                -e DB_POSTGRESDB_SCHEMA=${ENV}_schema \
                -e DB_POSTGRESDB_USER=postgres \
                -e DB_POSTGRESDB_PASSWORD=postgrespass \
                -e N8N_BASE_URL=https://$SUB_N.$DOMAIN/ \
                -e WEBHOOK_TUNNEL_URL=https://$SUB_N.$DOMAIN/ \
                -e REDIS_HOST=redis_$ENV \
                -v n8n_${ENV}_data:/home/node/.n8n \
                -l traefik.enable=true \
                -l traefik.http.routers.n8n_$ENV.rule=Host\(\`$SUB_N.$DOMAIN\`\) \
                -l traefik.http.routers.n8n_$ENV.entrypoints=websecure \
                -l traefik.http.routers.n8n_$ENV.tls.certresolver=le \
                -l traefik.http.services.n8n_$ENV.loadbalancer.server.port=5678 \
                n8nio/n8n:latest
        fi
    fi
    
    # 5. Evolution API
    if ! has evolution_$ENV; then
        ask_yn E y "Criar Evolution ($ENV)?"
        if [[ $E == y ]]; then
            say "📱 Configurando Evolution API ($ENV)"
            docker run -d --name evolution_$ENV --network $NET \
                -e SERVER_URL=https://$SUB_E.$DOMAIN \
                -e DATABASE_PROVIDER=postgresql \
                -e DATABASE_CONNECTION_URI="postgresql://postgres:postgrespass@pg_shared:5432/postgres?schema=${ENV}_schema" \
                -e CACHE_REDIS_URI="redis://redis_$ENV:6379" \
                -l traefik.enable=true \
                -l traefik.http.routers.evol_$ENV.rule=Host\(\`$SUB_E.$DOMAIN\`\) \
                -l traefik.http.routers.evol_$ENV.entrypoints=websecure \
                -l traefik.http.routers.evol_$ENV.tls.certresolver=le \
                -l traefik.http.services.evol_$ENV.loadbalancer.server.port=3000 \
                -v evol_${ENV}_data:/app/data \
                evoapicloud/evolution-api:v2.3.0
            
            # Criar schema no PostgreSQL
            docker exec pg_shared psql -U postgres -c "CREATE SCHEMA IF NOT EXISTS \"${ENV}_schema\";" || true
        fi
    fi
    
    # Salvar configurações do ambiente
    cat > "$DIR/environment.conf" <<EOF
ENV=$ENV
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SUB_T=$SUB_T
SUB_P=$SUB_P
SUB_N=$SUB_N
SUB_E=$SUB_E
OFFSET=$OFFSET
TRAEFIK_USED=$existing_traefik
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    success "🎉 Ambiente '$ENV' criado com sucesso!"
    echo ""
    echo "📋 URLs do ambiente:"
    if [ -n "$existing_traefik" ]; then
        echo " Traefik   → Usando existente: $existing_traefik"
    else
        echo " Traefik   → https://$SUB_T.$DOMAIN  (admin / changeMe!)"
    fi
    echo " Portainer → https://$SUB_P.$DOMAIN"
    echo " n8n       → https://$SUB_N.$DOMAIN"
    echo " Evolution → https://$SUB_E.$DOMAIN/api/health"
}

# Função para fazer backup
backup_environment() {
    say "💾 Sistema de Backup"
    
    echo ""
    echo "📋 Opções de backup:"
    echo "   1) 📦 Backup de ambiente específico"
    echo "   2) 🌐 Backup de todos os ambientes"
    echo "   3) 🗃️  Backup apenas do PostgreSQL (todos os schemas)"
    echo "   4) 🔍 Backup de schema específico do PostgreSQL"
    echo "   5) 📊 Listar backups existentes"
    echo "   6) 🔄 Restaurar backup"
    echo "   0) ⬅️  Voltar"
    
    local option=""
    ask option "" "Escolha uma opção"
    
    case $option in
        1) backup_specific_environment ;;
        2) backup_all_environments ;;
        3) backup_all_postgres ;;
        4) backup_specific_schema ;;
        5) list_backups ;;
        6) restore_backup ;;
        0) return 0 ;;
        *) error "Opção inválida" ;;
    esac
}

# Backup de ambiente específico
backup_specific_environment() {
    local ENV=""
    ask ENV "" "Nome do ambiente para backup"
    [ -z "$ENV" ] && { error "Nome do ambiente é obrigatório"; return 1; }
    
    local backup_name="env_${ENV}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    say "📦 Fazendo backup do ambiente '$ENV'"
    mkdir -p "$backup_path"
    
    # Backup de volumes Docker
    say "💾 Backup de volumes Docker"
    local volumes=(
        "portainer_data_$ENV"
        "n8n_${ENV}_data"
        "evol_${ENV}_data"
        "traefik_acme_$ENV"
    )
    
    for volume in "${volumes[@]}"; do
        if docker volume ls -q | grep -q "^$volume$"; then
            echo "   📁 Fazendo backup do volume: $volume"
            docker run --rm -v "$volume":/source -v "$backup_path":/backup alpine \
                tar czf "/backup/${volume}.tar.gz" -C /source .
        fi
    done
    
    # Backup de configurações
    if [ -d "$BASE_DIR/$ENV" ]; then
        say "⚙️  Backup de configurações"
        cp -r "$BASE_DIR/$ENV" "$backup_path/config"
    fi
    
    # Backup do schema PostgreSQL
    if has pg_shared; then
        say "🗃️  Backup do schema PostgreSQL"
        docker exec pg_shared pg_dump -U postgres --schema="${ENV}_schema" --create --clean \
            postgres > "$backup_path/schema_${ENV}.sql" 2>/dev/null || true
    fi
    
    # Criar manifest do backup
    cat > "$backup_path/manifest.json" <<EOF
{
    "backup_type": "environment",
    "environment": "$ENV",
    "timestamp": "$(date -Iseconds)",
    "volumes": [$(printf '"%s",' "${volumes[@]}" | sed 's/,$//')],
    "has_config": $([ -d "$BASE_DIR/$ENV" ] && echo "true" || echo "false"),
    "has_postgres": $(has pg_shared && echo "true" || echo "false")
}
EOF
    
    success "✅ Backup concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

# Backup de todos os ambientes
backup_all_environments() {
    local backup_name="all_environments_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    say "🌐 Fazendo backup de todos os ambientes"
    mkdir -p "$backup_path"
    
    # Encontrar todos os ambientes
    local environments=($(find $BASE_DIR -maxdepth 1 -type d -name "*" | grep -v "^$BASE_DIR$" | xargs -n1 basename | sort))
    
    if [ ${#environments[@]} -eq 0 ]; then
        warn "Nenhum ambiente encontrado para backup"
        return 1
    fi
    
    echo "🔍 Ambientes encontrados: ${environments[*]}"
    
    # Backup do PostgreSQL completo
    if has pg_shared; then
        say "🐘 Backup completo do PostgreSQL"
        docker exec pg_shared pg_dumpall -U postgres > "$backup_path/postgres_full.sql"
    fi
    
    # Backup de todos os volumes
    say "💾 Backup de todos os volumes"
    local all_volumes=($(docker volume ls --format "{{.Name}}" | grep -E "(portainer_data_|n8n_.*_data|evol_.*_data|traefik_acme_)" | sort))
    
    for volume in "${all_volumes[@]}"; do
        echo "   📁 Fazendo backup do volume: $volume"
        docker run --rm -v "$volume":/source -v "$backup_path":/backup alpine \
            tar czf "/backup/${volume}.tar.gz" -C /source .
    done
    
    # Backup de todas as configurações
    say "⚙️  Backup de configurações"
    for env in "${environments[@]}"; do
        if [ -d "$BASE_DIR/$env" ]; then
            cp -r "$BASE_DIR/$env" "$backup_path/config_$env"
        fi
    done
    
    # Criar manifest do backup
    cat > "$backup_path/manifest.json" <<EOF
{
    "backup_type": "all_environments",
    "environments": [$(printf '"%s",' "${environments[@]}" | sed 's/,$//')],
    "timestamp": "$(date -Iseconds)",
    "volumes": [$(printf '"%s",' "${all_volumes[@]}" | sed 's/,$//')],
    "has_postgres": $(has pg_shared && echo "true" || echo "false")
}
EOF
    
    success "✅ Backup completo concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

# Backup de todos os schemas PostgreSQL
backup_all_postgres() {
    if ! has pg_shared; then
        error "PostgreSQL compartilhado não encontrado"
        return 1
    fi
    
    local backup_name="postgres_all_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name.sql"
    
    say "🗃️  Fazendo backup completo do PostgreSQL"
    docker exec pg_shared pg_dumpall -U postgres > "$backup_path"
    
    success "✅ Backup do PostgreSQL concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

# Backup de schema específico
backup_specific_schema() {
    if ! has pg_shared; then
        error "PostgreSQL compartilhado não encontrado"
        return 1
    fi
    
    # Listar schemas disponíveis
    echo "🔍 Schemas disponíveis:"
    local schemas=($(docker exec pg_shared psql -U postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%_schema';" | tr -d ' ' | grep -v '^$'))
    
    if [ ${#schemas[@]} -eq 0 ]; then
        warn "Nenhum schema de ambiente encontrado"
        return 1
    fi
    
    local i=1
    for schema in "${schemas[@]}"; do
        echo "   $i) $schema"
        ((i++))
    done
    
    local choice=""
    ask choice "" "Escolha o schema (número ou nome)"
    
    local selected_schema=""
    if [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#schemas[@]} ]; then
        selected_schema="${schemas[$((choice-1))]}"
    else
        selected_schema="$choice"
    fi
    
    # Verificar se schema existe
    if ! printf '%s\n' "${schemas[@]}" | grep -q "^$selected_schema$"; then
        error "Schema '$selected_schema' não encontrado"
        return 1
    fi
    
    local backup_name="schema_${selected_schema}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name.sql"
    
    say "🗃️  Fazendo backup do schema '$selected_schema'"
    docker exec pg_shared pg_dump -U postgres --schema="$selected_schema" --create --clean \
        postgres > "$backup_path"
    
    success "✅ Backup do schema concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

# Listar backups existentes
list_backups() {
    say "📊 Backups existentes"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        warn "Nenhum backup encontrado em $BACKUP_DIR"
        return 0
    fi
    
    echo ""
    echo "📁 Diretório de backups: $BACKUP_DIR"
    echo ""
    
    # Listar backups com detalhes
    local backups=($(find "$BACKUP_DIR" -maxdepth 1 -type d -name "*" | grep -v "^$BACKUP_DIR$" | sort -r))
    local sql_backups=($(find "$BACKUP_DIR" -maxdepth 1 -name "*.sql" | sort -r))
    
    if [ ${#backups[@]} -gt 0 ]; then
        echo "📦 Backups de ambiente:"
        for backup in "${backups[@]}"; do
            local name=$(basename "$backup")
            local size=$(du -sh "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
            
            echo "   📁 $name"
            echo "      📊 Tamanho: $size"
            echo "      📅 Data: $date"
            
            # Mostrar manifest se existir
            if [ -f "$backup/manifest.json" ]; then
                local backup_type=$(jq -r '.backup_type' "$backup/manifest.json" 2>/dev/null || echo "unknown")
                echo "      🏷️  Tipo: $backup_type"
            fi
            echo ""
        done
    fi
    
    if [ ${#sql_backups[@]} -gt 0 ]; then
        echo "🗃️  Backups SQL:"
        for backup in "${sql_backups[@]}"; do
            local name=$(basename "$backup")
            local size=$(du -sh "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
            
            echo "   📄 $name"
            echo "      📊 Tamanho: $size"
            echo "      📅 Data: $date"
            echo ""
        done
    fi
    
    # Estatísticas gerais
#!/usr/bin/env bash

# Adicionar ao início do arquivo, após as configurações globais
BACKUP_DIR=/root/backup

# Adicionar esta função após install_dependencies()
# Função para detectar Traefik existente
detect_existing_traefik() {
    local existing_traefiks=($(docker ps -a --format '{{.Names}}' | grep '^traefik_' || true))
    
    if [ ${#existing_traefiks[@]} -gt 0 ]; then
        echo "${existing_traefiks[0]}"
        return 0
    else
        echo ""
        return 1
    fi
}

# Substituir a função install_dependencies() existente por esta versão melhorada
install_dependencies() {
    say "🔧 Verificando dependências"
    apt-get update -y
    apt-get install -y apparmor-utils curl jq
    
    if ! command -v docker >/dev/null; then
        say "📦 Instalando Docker"
        curl -fsSL https://get.docker.com | sh
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        say "📦 Instalando Docker Compose"
        apt-get install -y docker-compose-plugin
    fi
    
    # Criar rede proxy se não existir
    if ! docker network ls --format '{{.Name}}' | grep -q "^$NET$"; then
        docker network create $NET
    fi
    
    # Criar diretório de backup
    mkdir -p "$BACKUP_DIR"
}

# Melhorar a função analyze_environments() existente
analyze_environments() {
    say "🔍 Analisando ambientes existentes"
    
    local environments=()
    local dirs=($(find $BASE_DIR -maxdepth 1 -type d -name "*" | grep -v "^$BASE_DIR$" | sort))
    
    echo -e "\n📊 RELATÓRIO DO SISTEMA:"
    echo "========================"
    
    # Detectar Traefik existente
    local existing_traefik=$(detect_existing_traefik || true)
    if [ -n "$existing_traefik" ]; then
        info "🚦 Traefik detectado: $existing_traefik (será reutilizado para novos ambientes)"
    else
        warn "🚦 Nenhum Traefik encontrado - será necessário instalar um"
    fi
    
    # Verificar diretórios de ambiente
    if [ ${#dirs[@]} -gt 0 ]; then
        echo -e "\n📁 Diretórios encontrados:"
        for dir in "${dirs[@]}"; do
            local env_name=$(basename "$dir")
            echo "   • $env_name"
            environments+=("$env_name")
        done
    else
        echo -e "\n📁 Nenhum diretório de ambiente encontrado"
    fi
    
    # Verificar containers por ambiente
    echo -e "\n🐳 Containers por ambiente:"
    local all_containers=$(docker ps -a --format "{{.Names}}" | sort)
    local env_containers=()
    
    # Agrupar containers por ambiente
    while IFS= read -r container; do
        if [[ $container =~ ^(traefik|portainer|n8n|evolution|redis)_(.+)$ ]]; then
            local service="${BASH_REMATCH[1]}"
            local env="${BASH_REMATCH[2]}"
            local status=$(docker ps --format "{{.Status}}" --filter name="^${container}$")
            
            # Armazenar informações do container
            env_containers+=("$env:$service:$container:$status")
        fi
    done <<< "$all_containers"
    
    # Exibir containers agrupados por ambiente
    local current_env=""
    for item in $(printf '%s\n' "${env_containers[@]}" | sort); do
        IFS=':' read -r env service container status <<< "$item"
        
        if [ "$env" != "$current_env" ]; then
            echo -e "\n   📦 Ambiente: $env"
            current_env="$env"
        fi
        
        local status_icon="❌"
        [[ $status =~ ^Up ]] && status_icon="✅"
        
        echo "      $status_icon $service ($container) - $status"
    done
    
    # Verificar volumes
    echo -e "\n💾 Volumes Docker:"
    local volumes=$(docker volume ls --format "{{.Name}}" | grep -E "(traefik_acme_|portainer_data_|n8n_.*_data|evol_.*_data)" | sort || true)
    if [ -n "$volumes" ]; then
        while IFS= read -r volume; do
            local size=$(docker system df -v | grep "$volume" | awk '{print $3}' || echo "N/A")
            echo "   💾 $volume ($size)"
        done <<< "$volumes"
    else
        echo "   Nenhum volume de ambiente encontrado"
    fi
    
    # Verificar rede
    echo -e "\n🌐 Rede Docker:"
    if docker network ls --format '{{.Name}}' | grep -q "^$NET$"; then
        local containers_in_network=$(docker network inspect $NET --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
        echo "   ✅ Rede '$NET' existe"
        if [ -n "$containers_in_network" ]; then
            echo "   🔗 Containers conectados: $containers_in_network"
        fi
    else
        echo "   ❌ Rede '$NET' não encontrada"
    fi
    
    # Verificar containers compartilhados
    echo -e "\n🔗 Serviços Compartilhados:"
    if has pg_shared; then
        local pg_status=$(docker ps --format "{{.Status}}" --filter name="^pg_shared$")
        echo "   ✅ PostgreSQL compartilhado - $pg_status"
        
        # Verificar schemas no PostgreSQL
        local schemas=$(docker exec pg_shared psql -U postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%_schema';" 2>/dev/null | tr -d ' ' | grep -v '^$' || true)
        if [ -n "$schemas" ]; then
            echo "   🗃️  Schemas encontrados:"
            while IFS= read -r schema; do
                echo "      • $schema"
            done <<< "$schemas"
        fi
    else
        echo "   ❌ PostgreSQL compartilhado não encontrado"
    fi
    
    # Retornar ambientes encontrados
    printf '%s\n' "${environments[@]}"
}

# Modificar a função create_environment() para detectar Traefik automaticamente
# Substituir a seção do Traefik por:
create_environment() {
    say "🚀 Criando novo ambiente"
    
    # Detectar Traefik existente
    local existing_traefik=$(detect_existing_traefik || true)
    
    # Defaults
    local ENV="" DOMAIN="exemplo.com.br" EMAIL=""
    local SUB_T="" SUB_P="" SUB_N="" SUB_E=""
    local OFFSET=10 FORCE_T=""
    
    ask ENV "" "Nome do ambiente (ex: v2, prod, dev)"
    [ -z "$ENV" ] && { error "Nome do ambiente é obrigatório"; return 1; }
    
    # Verificar se ambiente já existe
    if [ -d "$BASE_DIR/$ENV" ]; then
        warn "Ambiente '$ENV' já existe!"
        ask_yn OVERWRITE n "Sobrescrever ambiente existente?"
        [ "$OVERWRITE" != "y" ] && return 1
    fi
    
    ask DOMAIN "$DOMAIN" "Domínio principal"
    EMAIL="admin@$DOMAIN"
    ask EMAIL "$EMAIL" "Email Let's Encrypt"
    
    SUB_T="traefik$ENV"
    SUB_P="portainer$ENV"
    SUB_N="n8n$ENV"
    SUB_E="evol$ENV"
    
    ask SUB_T "$SUB_T" "Subdomínio Traefik"
    ask SUB_P "$SUB_P" "Subdomínio Portainer"
    ask SUB_N "$SUB_N" "Subdomínio n8n"
    ask SUB_E "$SUB_E" "Subdomínio Evolution"
    ask OFFSET "$OFFSET" "Offset portas externas"
    
    # Decisão sobre Traefik baseada na detecção
    if [ -n "$existing_traefik" ]; then
        info "🚦 Traefik existente detectado: $existing_traefik"
        info "🔄 Reutilizando Traefik existente para o novo ambiente"
        FORCE_T="n"
    else
        ask FORCE_T "y" "Nenhum Traefik encontrado. Instalar Traefik? (y/n)"
    fi
    
    local DIR="$BASE_DIR/$ENV"
    mkdir -p "$DIR"
    
    # Hash bcrypt para admin:changeMe!
    local HASH='$2y$05$f0Bm1Ri7wFkVIkGdVUq/6.3/jbpTOyBp34g6fMk9TvqphrJ9Xrnu2'
    local LABEL_HASH="admin:$$${HASH#\$}"
    
    # Criar PostgreSQL compartilhado se não existir
    if ! has pg_shared; then
        say "🐘 Criando PostgreSQL compartilhado"
        docker run -d --name pg_shared --network $NET \
            -e POSTGRES_PASSWORD=postgrespass \
            -v pg_shared:/var/lib/postgresql/data \
            postgres:15-alpine
        sleep 5
    fi
    
    # 1. Traefik (apenas se necessário)
    local I_T="n"
    [[ $FORCE_T == "y" ]] && I_T="y"
    
    if [[ $I_T == y ]]; then
        # Resto da configuração do Traefik permanece igual...
    fi
    
    # Resto da função permanece igual...
    
    # Salvar configurações do ambiente (incluir info sobre Traefik)
    cat > "$DIR/environment.conf" <<EOF
ENV=$ENV
DOMAIN=$DOMAIN
EMAIL=$EMAIL
SUB_T=$SUB_T
SUB_P=$SUB_P
SUB_N=$SUB_N
SUB_E=$SUB_E
OFFSET=$OFFSET
TRAEFIK_USED=$existing_traefik
CREATED=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    success "🎉 Ambiente '$ENV' criado com sucesso!"
    echo ""
    echo "📋 URLs do ambiente:"
    if [ -n "$existing_traefik" ]; then
        echo " Traefik   → Usando existente: $existing_traefik"
    else
        echo " Traefik   → https://$SUB_T.$DOMAIN  (admin / changeMe!)"
    fi
    echo " Portainer → https://$SUB_P.$DOMAIN"
    echo " n8n       → https://$SUB_N.$DOMAIN"
    echo " Evolution → https://$SUB_E.$DOMAIN/api/health"
}

# Adicionar todas as funções de backup
backup_environment() {
    say "💾 Sistema de Backup"
    
    echo ""
    echo "📋 Opções de backup:"
    echo "   1) 📦 Backup de ambiente específico"
    echo "   2) 🌐 Backup de todos os ambientes"
    echo "   3) 🗃️  Backup apenas do PostgreSQL (todos os schemas)"
    echo "   4) 🔍 Backup de schema específico do PostgreSQL"
    echo "   5) 📊 Listar backups existentes"
    echo "   6) 🔄 Restaurar backup"
    echo "   0) ⬅️  Voltar"
    
    local option=""
    ask option "" "Escolha uma opção"
    
    case $option in
        1) backup_specific_environment ;;
        2) backup_all_environments ;;
        3) backup_all_postgres ;;
        4) backup_specific_schema ;;
        5) list_backups ;;
        6) restore_backup ;;
        0) return 0 ;;
        *) error "Opção inválida" ;;
    esac
}

backup_specific_environment() {
    local ENV=""
    ask ENV "" "Nome do ambiente para backup"
    [ -z "$ENV" ] && { error "Nome do ambiente é obrigatório"; return 1; }
    
    local backup_name="env_${ENV}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    say "📦 Fazendo backup do ambiente '$ENV'"
    mkdir -p "$backup_path"
    
    # Backup de volumes Docker
    say "💾 Backup de volumes Docker"
    local volumes=(
        "portainer_data_$ENV"
        "n8n_${ENV}_data"
        "evol_${ENV}_data"
        "traefik_acme_$ENV"
    )
    
    for volume in "${volumes[@]}"; do
        if docker volume ls -q | grep -q "^$volume$"; then
            echo "   📁 Fazendo backup do volume: $volume"
            docker run --rm -v "$volume":/source -v "$backup_path":/backup alpine \
                tar czf "/backup/${volume}.tar.gz" -C /source .
        fi
    done
    
    # Backup de configurações
    if [ -d "$BASE_DIR/$ENV" ]; then
        say "⚙️  Backup de configurações"
        cp -r "$BASE_DIR/$ENV" "$backup_path/config"
    fi
    
    # Backup do schema PostgreSQL
    if has pg_shared; then
        say "🗃️  Backup do schema PostgreSQL"
        docker exec pg_shared pg_dump -U postgres --schema="${ENV}_schema" --create --clean \
            postgres > "$backup_path/schema_${ENV}.sql" 2>/dev/null || true
    fi
    
    # Criar manifest do backup
    cat > "$backup_path/manifest.json" <<EOF
{
    "backup_type": "environment",
    "environment": "$ENV",
    "timestamp": "$(date -Iseconds)",
    "volumes": [$(printf '"%s",' "${volumes[@]}" | sed 's/,$//')],
    "has_config": $([ -d "$BASE_DIR/$ENV" ] && echo "true" || echo "false"),
    "has_postgres": $(has pg_shared && echo "true" || echo "false")
}
EOF
    
    success "✅ Backup concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

backup_all_environments() {
    local backup_name="all_environments_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    say "🌐 Fazendo backup de todos os ambientes"
    mkdir -p "$backup_path"
    
    # Encontrar todos os ambientes
    local environments=($(find $BASE_DIR -maxdepth 1 -type d -name "*" | grep -v "^$BASE_DIR$" | xargs -n1 basename | sort))
    
    if [ ${#environments[@]} -eq 0 ]; then
        warn "Nenhum ambiente encontrado para backup"
        return 1
    fi
    
    echo "🔍 Ambientes encontrados: ${environments[*]}"
    
    # Backup do PostgreSQL completo
    if has pg_shared; then
        say "🐘 Backup completo do PostgreSQL"
        docker exec pg_shared pg_dumpall -U postgres > "$backup_path/postgres_full.sql"
    fi
    
    # Backup de todos os volumes
    say "💾 Backup de todos os volumes"
    local all_volumes=($(docker volume ls --format "{{.Name}}" | grep -E "(portainer_data_|n8n_.*_data|evol_.*_data|traefik_acme_)" | sort))
    
    for volume in "${all_volumes[@]}"; do
        echo "   📁 Fazendo backup do volume: $volume"
        docker run --rm -v "$volume":/source -v "$backup_path":/backup alpine \
            tar czf "/backup/${volume}.tar.gz" -C /source .
    done
    
    # Backup de todas as configurações
    say "⚙️  Backup de configurações"
    for env in "${environments[@]}"; do
        if [ -d "$BASE_DIR/$env" ]; then
            cp -r "$BASE_DIR/$env" "$backup_path/config_$env"
        fi
    done
    
    # Criar manifest do backup
    cat > "$backup_path/manifest.json" <<EOF
{
    "backup_type": "all_environments",
    "environments": [$(printf '"%s",' "${environments[@]}" | sed 's/,$//')],
    "timestamp": "$(date -Iseconds)",
    "volumes": [$(printf '"%s",' "${all_volumes[@]}" | sed 's/,$//')],
    "has_postgres": $(has pg_shared && echo "true" || echo "false")
}
EOF
    
    success "✅ Backup completo concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

backup_all_postgres() {
    if ! has pg_shared; then
        error "PostgreSQL compartilhado não encontrado"
        return 1
    fi
    
    local backup_name="postgres_all_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name.sql"
    
    say "🗃️  Fazendo backup completo do PostgreSQL"
    docker exec pg_shared pg_dumpall -U postgres > "$backup_path"
    
    success "✅ Backup do PostgreSQL concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

backup_specific_schema() {
    if ! has pg_shared; then
        error "PostgreSQL compartilhado não encontrado"
        return 1
    fi
    
    # Listar schemas disponíveis
    echo "🔍 Schemas disponíveis:"
    local schemas=($(docker exec pg_shared psql -U postgres -t -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '%_schema';" | tr -d ' ' | grep -v '^$'))
    
    if [ ${#schemas[@]} -eq 0 ]; then
        warn "Nenhum schema de ambiente encontrado"
        return 1
    fi
    
    local i=1
    for schema in "${schemas[@]}"; do
        echo "   $i) $schema"
        ((i++))
    done
    
    local choice=""
    ask choice "" "Escolha o schema (número ou nome)"
    
    local selected_schema=""
    if [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#schemas[@]} ]; then
        selected_schema="${schemas[$((choice-1))]}"
    else
        selected_schema="$choice"
    fi
    
    # Verificar se schema existe
    if ! printf '%s\n' "${schemas[@]}" | grep -q "^$selected_schema$"; then
        error "Schema '$selected_schema' não encontrado"
        return 1
    fi
    
    local backup_name="schema_${selected_schema}_$(date +%Y%m%d_%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name.sql"
    
    say "🗃️  Fazendo backup do schema '$selected_schema'"
    docker exec pg_shared pg_dump -U postgres --schema="$selected_schema" --create --clean \
        postgres > "$backup_path"
    
    success "✅ Backup do schema concluído: $backup_path"
    echo "📊 Tamanho do backup: $(du -sh "$backup_path" | cut -f1)"
}

list_backups() {
    say "📊 Backups existentes"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        warn "Nenhum backup encontrado em $BACKUP_DIR"
        return 0
    fi
    
    echo ""
    echo "📁 Diretório de backups: $BACKUP_DIR"
    echo ""
    
    # Listar backups com detalhes
    local backups=($(find "$BACKUP_DIR" -maxdepth 1 -type d -name "*" | grep -v "^$BACKUP_DIR$" | sort -r))
    local sql_backups=($(find "$BACKUP_DIR" -maxdepth 1 -name "*.sql" | sort -r))
    
    if [ ${#backups[@]} -gt 0 ]; then
        echo "📦 Backups de ambiente:"
        for backup in "${backups[@]}"; do
            local name=$(basename "$backup")
            local size=$(du -sh "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
            
            echo "   📁 $name"
            echo "      📊 Tamanho: $size"
            echo "      📅 Data: $date"
            
            # Mostrar manifest se existir
            if [ -f "$backup/manifest.json" ]; then
                local backup_type=$(jq -r '.backup_type' "$backup/manifest.json" 2>/dev/null || echo "unknown")
                echo "      🏷️  Tipo: $backup_type"
            fi
            echo ""
        done
    fi
    
    if [ ${#sql_backups[@]} -gt 0 ]; then
        echo "🗃️  Backups SQL:"
        for backup in "${sql_backups[@]}"; do
            local name=$(basename "$backup")
            local size=$(du -sh "$backup" | cut -f1)
            local date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
            
            echo "   📄 $name"
            echo "      📊 Tamanho: $size"
            echo "      📅 Data: $date"
            echo ""
        done
    fi
    
    # Estatísticas gerais
    local total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
    local backup_count=$((${#backups[@]} + ${#sql_backups[@]}))
    
    echo "📊 Resumo:"
    echo "   Total de backups: $backup_count"
    echo "   Espaço usado: $total_size"
}

restore_backup() {
    say "🔄 Restaurar Backup"
    
    list_backups
    
    echo ""
    local backup_name=""
    ask backup_name "" "Nome do backup para restaurar (sem extensão)"
    [ -z "$backup_name" ] && { error "Nome do backup é obrigatório"; return 1; }
    
    local backup_path="$BACKUP_DIR/$backup_name"
    local sql_path="$BACKUP_DIR/$backup_name.sql"
    
    if [ -d "$backup_path" ]; then
        # Restaurar backup de ambiente
        restore_environment_backup "$backup_path"
    elif [ -f "$sql_path" ]; then
        # Restaurar backup SQL
        restore_sql_backup "$sql_path"
    else
        error "Backup '$backup_name' não encontrado"
        return 1
    fi
}

restore_environment_backup() {
    local backup_path="$1"
    
    warn "⚠️  ATENÇÃO: A restauração pode sobrescrever dados existentes!"
    ask_yn CONFIRM n "Continuar com a restauração?"
    [ "$CONFIRM" != "y" ] && { echo "Restauração cancelada."; return 0; }
    
    say "🔄 Restaurando backup de ambiente"
    
    # Ler manifest se existir
    local env_name=""
    if [ -f "$backup_path/manifest.json" ]; then
        env_name=$(jq -r '.environment' "$backup_path/manifest.json" 2>/dev/null || echo "")
    fi
    
    if [ -z "$env_name" ]; then
        ask env_name "" "Nome do ambiente de destino"
        [ -z "$env_name" ] && { error "Nome do ambiente é obrigatório"; return 1; }
    fi
    
    # Restaurar volumes
    say "💾 Restaurando volumes"
    for volume_file in "$backup_path"/*.tar.gz; do
        if [ -f "$volume_file" ]; then
            local volume_name=$(basename "$volume_file" .tar.gz)
            echo "   📁 Restaurando volume: $volume_name"
            
            # Criar volume se não existir
            docker volume create "$volume_name" >/dev/null 2>&1 || true
            
            # Restaurar dados
            docker run --rm -v "$volume_name":/target -v "$backup_path":/backup alpine \
                tar xzf "/backup/$(basename "$volume_file")" -C /target
        fi
    done
    
    # Restaurar configurações
    if [ -d "$backup_path/config" ]; then
        say "⚙️  Restaurando configurações"
        cp -r "$backup_path/config" "$BASE_DIR/$env_name"
    fi
    
    # Restaurar schema PostgreSQL
    if [ -f "$backup_path/schema_${env_name}.sql" ] && has pg_shared; then
        say "🗃️  Restaurando schema PostgreSQL"
        docker exec -i pg_shared psql -U postgres < "$backup_path/schema_${env_name}.sql"
    fi
    
    success "✅ Backup restaurado com sucesso!"
}

restore_sql_backup() {
    local sql_path="$1"
    
    if ! has pg_shared; then
        error "PostgreSQL compartilhado não encontrado"
        return 1
    fi
    
    warn "⚠️  ATENÇÃO: A restauração SQL pode sobrescrever dados existentes!"
    ask_yn CONFIRM n "Continuar com a restauração?"
    [ "$CONFIRM" != "y" ] && { echo "Restauração cancelada."; return 0; }
    
    say "🗃️  Restaurando backup SQL"
    docker exec -i pg_shared psql -U postgres < "$sql_path"
    
    success "✅ Backup SQL restaurado com sucesso!"
}

# Adicionar função info()
info(){ echo -e "\033[1;36mℹ️  $*\033[0m"; }

# Modificar o main_menu() para incluir opção de backup
main_menu() {
    while true; do
        echo ""
        echo "🚀 GERENCIADOR DE AMBIENTES VPS"
        echo "==============================="
        echo ""
        echo "1) 🔍 Analisar sistema"
        echo "2) 🆕 Criar novo ambiente"
        echo "3) 🗑️  Deletar ambiente"
        echo "4) 🔧 Manutenção de ambiente"
        echo "5) 💾 Sistema de Backup"
        echo "6) 📊 Status geral"
        echo "0) ❌ Sair"
        echo ""
        
        local option=""
        ask option "" "Escolha uma opção"
        
        case $option in
            1)
                analyze_environments > /dev/null
                ;;
            2)
                create_environment
                ;;
            3)
                delete_environment
                ;;
            4)
                maintain_environment
                ;;
            5)
                backup_environment
                ;;
            6)
                say "📊 Status geral do sistema"
                echo ""
                echo "🐳 Containers ativos:"
                docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                echo ""
                echo "💾 Uso de volumes:"
                docker system df -v
                ;;
            0)
                success "👋 Até logo!"
                exit 0
                ;;
            *)
                error "Opção inválida"
                ;;
        esac
        
        echo ""
        read -p "Pressione Enter para continuar..."
    done
}