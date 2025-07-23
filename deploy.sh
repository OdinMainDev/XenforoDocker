#!/bin/bash

# XenForo Docker Deployment Script
# This script orchestrates the deployment of XenForo forum with separate web and database services

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f ".env" ]; then
    set -o allexport
    source .env
    set +o allexport
fi

# Configuration
PROJECT_NAME="xenforo"
WEB_COMPOSE_FILE="docker-compose.web.yml"
DB_COMPOSE_FILE="docker-compose.db.yml"
BACKUP_DIR="./mysql_backups"
LOGS_DIR="./logs"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if Docker and Docker Compose are installed
check_dependencies() {
    print_status "Checking dependencies..."
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command -v docker compose &> /dev/null; then
        print_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    
    print_success "Dependencies check passed"
}

# Function to create necessary directories
create_directories() {
    print_status "Creating necessary directories..."
    
    directories=(
        "nginx/conf.d"
        "nginx/ssl"
        "mysql/conf.d"
        "mysql/init"
        "php"
        "scripts"
        "xenforo_app"
        "$BACKUP_DIR"
        "$LOGS_DIR/nginx"
        "$LOGS_DIR/php"
        "$LOGS_DIR/mysql"
    )
    
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            print_status "Created directory: $dir"
        fi
    done
    
    # Set proper permissions for MySQL logs
    if [ -d "$LOGS_DIR/mysql" ]; then
        chmod 755 "$LOGS_DIR/mysql"
        print_status "Set permissions for MySQL logs directory"
    fi
    
    print_success "Directories created successfully"
}

# Function to generate .env file
generate_env() {
    print_status "Generating .env file..."
    
    if [ ! -f ".env" ]; then
        if [ -f ".env.example" ]; then
            cp .env.example .env
            print_status "Created .env from .env.example"
        else
            print_error ".env.example file not found"
            exit 1
        fi
        
        # Generate random passwords
        MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32)
        MYSQL_PASSWORD=$(openssl rand -base64 32)
        
        # Replace placeholders in .env file
        sed -i.bak "s/your_mysql_root_password_here/${MYSQL_ROOT_PASSWORD}/g" .env
        sed -i.bak "s/your_mysql_user_password_here/${MYSQL_PASSWORD}/g" .env
        
        # Remove backup file
        rm .env.bak
        
        print_status "Generated random passwords in .env file"
    fi
    
    # Set proper permissions for .env file
    chmod 600 .env
    print_success ".env file generated and secured"
}

# Function to set file permissions
set_permissions() {
    print_status "Setting proper file permissions..."
    
    # Set secure permissions for configuration files
    find ./nginx -type f -exec chmod 644 {} \;
    find ./mysql -type f -exec chmod 644 {} \;
    find ./php -type f -exec chmod 644 {} \;
    
    # Set permissions for XenForo directory
    if [ -d "./xenforo_app" ]; then
        find ./xenforo_app -type f -exec chmod 644 {} \;
        find ./xenforo_app -type d -exec chmod 755 {} \;
        
        # Special permissions for XenForo data directories
        if [ -d "./xenforo_app/data" ]; then
            chmod -R 777 ./xenforo_app/data
        fi
        if [ -d "./xenforo_app/internal_data" ]; then
            chmod -R 777 ./xenforo_app/internal_data
        fi
        
        print_status "Set permissions for XenForo directories"
    fi
    
    print_success "File permissions set correctly"
}

# Function to start database services
start_database() {
    print_status "Starting database services..."
    
    docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" up -d
    
    # Wait for database to be ready
    print_status "Waiting for database to be ready..."
    sleep 30
    
    # Test database connection with retry
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        print_status "Checking database connection (attempt $attempt/$max_attempts)..."
        
        if docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" &> /dev/null; then
            print_success "Database services started successfully"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            print_status "Database not ready yet, waiting 10 seconds..."
            sleep 10
        fi
        
        attempt=$((attempt + 1))
    done
    
    print_error "Database connection failed after $max_attempts attempts"
    print_status "Database may still be starting up. You can check logs with: ./deploy.sh logs mysql"
    # Don't exit, just warn - database might still be starting
    return 1
}

# Function to start web services
start_web() {
    print_status "Starting web services..."
    
    docker compose -f "$WEB_COMPOSE_FILE" -p "${PROJECT_NAME}_web" up -d
    
    print_success "Web services started successfully"
}

# Function to stop web services
stop_web() {
    print_status "Stopping web services..."
    
    docker compose -f "$WEB_COMPOSE_FILE" -p "${PROJECT_NAME}_web" down
    
    print_success "Web services stopped"
}

# Function to stop database services
stop_db() {
    print_status "Stopping database services..."
    
    docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" down
    
    print_success "Database services stopped"
}

# Function to stop all services
stop_services() {
    print_status "Stopping all services..."
    
    stop_web
    stop_db
    
    print_success "All services stopped"
}

# Function to restart web services
restart_web() {
    print_status "Restarting web services..."
    
    stop_web
    sleep 5
    start_web
    
    print_success "Web services restarted"
}

# Function to restart database services
restart_db() {
    print_status "Restarting database services..."
    
    stop_db
    sleep 5
    start_database
    
    print_success "Database services restarted"
}

# Function to restart all services
restart_services() {
    print_status "Restarting all services..."
    
    stop_services
    sleep 5
    start_database
    start_web
    
    print_success "All services restarted"
}

# Function to show logs
show_logs() {
    local service=$1
    
    if [ -z "$service" ]; then
        print_status "Showing logs for all services..."
        docker compose -f "$WEB_COMPOSE_FILE" -p "${PROJECT_NAME}_web" logs -f &
        docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" logs -f &
        wait
    else
        case $service in
            "web"|"nginx"|"php")
                docker compose -f "$WEB_COMPOSE_FILE" -p "${PROJECT_NAME}_web" logs -f $service
                ;;
            "db"|"mysql")
                docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" logs -f $service
                ;;
            *)
                print_error "Unknown service: $service"
                exit 1
                ;;
        esac
    fi
}

# Function to run database backup
backup_database() {
    print_status "Running manual database backup..."
    
    docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" run --rm \
        -e RUN_ONCE=true \
        mysql-backup
    
    print_success "Manual database backup completed"
}

# Function to show status
show_status() {
    print_status "Service Status:"
    echo
    echo "Web Services:"
    docker compose -f "$WEB_COMPOSE_FILE" -p "${PROJECT_NAME}_web" ps
    echo
    echo "Database Services:"
    docker compose -f "$DB_COMPOSE_FILE" -p "${PROJECT_NAME}_db" ps
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo
    echo "Commands:"
    echo "  start       Start all services (database first, then web)"
    echo "  start-db    Start database services only"
    echo "  start-web   Start web services only"
    echo "  stop        Stop all services"
    echo "  stop-db     Stop database services only"
    echo "  stop-web    Stop web services only"
    echo "  restart     Restart all services"
    echo "  restart-db  Restart database services only"
    echo "  restart-web Restart web services only"
    echo "  status      Show service status"
    echo "  logs        Show logs for all services"
    echo "  logs [svc]  Show logs for specific service (web,nginx,php,db,mysql)"
    echo "  backup      Run database backup"
    echo "  setup       Initial setup (create directories, generate .env)"
    echo "  help        Show this help message"
}

# Main script logic
case "${1:-start}" in
    "setup")
        check_dependencies
        create_directories
        generate_env
        set_permissions
        print_success "Setup completed successfully"
        print_warning "Please configure your nginx, php, and mysql settings before starting services"
        ;;
    "start")
        check_dependencies
        create_directories
        generate_env
        set_permissions
        start_database
        start_web
        show_status
        print_success "XenForo deployment completed successfully"
        ;;
    "start-db")
        check_dependencies
        generate_env
        start_database
        ;;
    "start-web")
        check_dependencies
        generate_env
        start_web
        ;;
    "stop")
        stop_services
        ;;
    "stop-db")
        stop_db
        ;;
    "stop-web")
        stop_web
        ;;
    "restart")
        restart_services
        ;;
    "restart-db")
        restart_db
        ;;
    "restart-web")
        restart_web
        ;;
    "status")
        show_status
        ;;
    "logs")
        show_logs $2
        ;;
    "backup")
        backup_database
        ;;
    "help")
        show_usage
        ;;
    *)
        print_error "Unknown command: $1"
        show_usage
        exit 1
        ;;
esac