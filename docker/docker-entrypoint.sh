#!/bin/bash
set -e

echo "==> Starting SurfsUp Laravel Application..."

# ============================================
# Environment Setup
# ============================================

# Check if .env file exists in persistent volume, if so, use it
if [ -f "/config/.env" ]; then
    echo "==> Using .env from persistent volume..."
    cp /config/.env /var/www/html/.env
    chown www-data:www-data /var/www/html/.env
else
    echo "==> WARNING: No .env file found in /config volume!"
    echo "==> Please mount your .env file to /config/.env"
fi

# ============================================
# Wait for Database
# ============================================

echo "==> Waiting for database connection..."

DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
DB_DATABASE="${DB_DATABASE:-laravel}"

max_tries=30
counter=0

until mariadb -h"$DB_HOST" -P"$DB_PORT" -u"${DB_USERNAME:-root}" -p"${DB_PASSWORD:-}" -e "SELECT 1" > /dev/null 2>&1; do
    counter=$((counter+1))
    if [ $counter -gt $max_tries ]; then
        echo "==> ERROR: Could not connect to database after $max_tries attempts"
        echo "==> Connection details: $DB_HOST:$DB_PORT"
        exit 1
    fi
    echo "==> Waiting for database... (attempt $counter/$max_tries)"
    sleep 2
done

echo "==> Database connection established!"

# ============================================
# Database Initialization
# ============================================

# Check if database is empty and import SQL if provided
if [ -f "/sql-import/seed.sql" ]; then
    # Check if tables exist
    TABLE_COUNT=$(mariadb -h"$DB_HOST" -P"$DB_PORT" -u"${DB_USERNAME:-root}" -p"${DB_PASSWORD:-}" -D"$DB_DATABASE" -e "SHOW TABLES;" -s --skip-column-names | wc -l)

    if [ "$TABLE_COUNT" -eq 0 ]; then
        echo "==> Database is empty. Importing seed.sql..."
        mariadb -h"$DB_HOST" -P"$DB_PORT" -u"${DB_USERNAME:-root}" -p"${DB_PASSWORD:-}" "$DB_DATABASE" < /sql-import/seed.sql
        echo "==> Database import completed!"
    else
        echo "==> Database already contains tables (count: $TABLE_COUNT). Skipping import."
    fi
else
    echo "==> No seed.sql file found in /sql-import volume. Skipping database import."
fi

# ============================================
# Laravel Optimizations
# ============================================

echo "==> Running Laravel optimizations..."

# Run migrations
echo "==> Running database migrations..."
php /var/www/html/artisan migrate --force --no-interaction

# Clear and cache configuration
echo "==> Caching configuration..."
php /var/www/html/artisan config:cache
php /var/www/html/artisan route:cache
php /var/www/html/artisan view:cache

# Create storage link if it doesn't exist
if [ ! -L "/var/www/html/public/storage" ]; then
    echo "==> Creating storage symbolic link..."
    php /var/www/html/artisan storage:link
fi

# Set proper permissions
echo "==> Setting permissions..."
chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache
chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache

# ============================================
# Filament Setup
# ============================================

echo "==> Running Filament optimizations..."
php /var/www/html/artisan filament:optimize

# ============================================
# Warm Cache
# ============================================
echo "==> Warming up cache..."
php /var/www/html/artisan cache:warm

# ============================================
# Health Check
# ============================================

echo "==> Application is ready!"
echo "==> Environment: ${APP_ENV:-production}"
echo "==> Debug mode: ${APP_DEBUG:-false}"
echo "==> Database: $DB_HOST:$DB_PORT/$DB_DATABASE"

# Execute CMD
exec "$@"
