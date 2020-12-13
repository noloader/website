#!/usr/bin/env bash

# update-wiki.sh performs maintenance on the website's wiki installation.
# The script does three things, give or take. First it updates GitHub
# based components in skins/ and extensions/. Second, it {re}sets
# ownership and permissions on some files and folders, including logging
# files in /var/log. Third, it runs MediaWiki's update.php and then restarts
# the Apache service. update.php is important and it must be run anytime
# a change occurs.
#
# The script is located in the website directory, which is /var/www/html/.
# We should probably schedule this script as a cron job.

THIS_DIR=$(pwd)
function finish {
    cd "$THIS_DIR"
}
trap finish EXIT

# Privileges? Exit 0 to keep things moving along
# Errors will be printed to the terminal
if [[ ($(id -u) != "0") ]]; then
    echo "You must be root to update the wiki"
    exit 0
fi

# Important variables
WIKI_DIR="/var/www/html/w"
WIKI_REL=REL1_34
PHP_DIR=/opt/rh/rh-php72/root/usr/bin
LOG_DIR="/var/log"

if [[ ! -d "${WIKI_DIR}" ]]; then
    echo "WIKI_DIR is not vaild."
    exit 1
fi

if [[ ! -d "${PHP_DIR}" ]]; then
    echo "PHP_DIR is not vaild."
    exit 1
fi

# This finds directories check'd out from Git and updates them. 
# It works surprisingly well. There has only been a couple of
# minor problems.
for dir in $(find "$WIKI_DIR/skins" -name '.git' 2>/dev/null); do
    cd "$dir/.."
    echo "Updating ${dir::-4}"
    git reset --hard HEAD && git pull && \
    git checkout -f "$WIKI_REL" && git pull
done

for dir in $(find "$WIKI_DIR/extensions" -name '.git' 2>/dev/null); do
    cd "$dir/.."
    echo "Updating ${dir::-4}"
    git reset --hard HEAD && git pull && \
    git checkout -f "$WIKI_REL" && git pull
done

# Remove all test frameworks
for dir in $(find "$WIKI_DIR" -iname 'test*' 2>/dev/null); do
    rm -rf "$dir" 2>/dev/null
done

# And benchmarks
for dir in $(find "$WIKI_DIR" -iname 'benchmark*' 2>/dev/null); do
    rm -rf "$dir" 2>/dev/null
done

if [[ -f "$WIKI_DIR/extensions/SyntaxHighlight/pygments/pygmentize" ]]; then
    chmod ug+x "$WIKI_DIR/extensions/SyntaxHighlight/pygments/pygmentize"
fi

if [[ -f "$WIKI_DIR/create-sitemap.sh" ]]; then
    echo "Creating MediaWiki sitemap"
    rm -rf "$WIKI_DIR/sitemap"
    bash "$WIKI_DIR/create-sitemap.sh" 1>/dev/null
fi

# Set proper ownership and permissions. This is required after unpacking a
# new MediaWiki or cloning a Skin or Extension. The permissions are never
# correct. Executable files will be missing +x, and images will have +x.

echo "Fixing MediaWiki permissions"
chown -R root:apache "$WIKI_DIR/"
chmod -R u+rw,g+r,g-w,o-rwx "$WIKI_DIR/"

# Make Python and PHP executable
echo "Fixing Python and PHP permissions"
for file in $(find "$WIKI_DIR" -type f -name '*.py' 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chmod u+rwx,g+rx,g-w,o-rwx "$file"
done
for file in $(find "$WIKI_DIR" -type f -name '*.php' 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chmod u+rwx,g+rx,g-w,o-rwx "$file"
done
for file in $(find "$WIKI_DIR" -type f -name '*.sh' 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chmod u+rwx,g+rx,g-w,o-rwx "$file"
done

# Images/ must be writable by apache group
echo "Fixing MediaWiki images/ permissions"
for dir in $(find "$WIKI_DIR/images" -type d 2>/dev/null); do
    if [[ ! -d "$dir" ]]; then continue; fi
    chmod ug+rwx,o-rwx "$dir"
done
for file in $(find "$WIKI_DIR/images" -type f 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chmod ug+rw,ug-x,o-rwx "$file"
done

echo "Fixing Apache data permissions"
for dir in "/var/lib/pear/" "/var/lib/php/"; do
    if [[ ! -d "$dir" ]]; then continue; fi
    chown -R apache:apache "$dir"
    chmod -R ug+rwx,o-rwx "$dir"
done

echo "Fixing Apache logging permissions"
for dir in $(find "$LOG_DIR" -type d -name 'httpd*' 2>/dev/null); do
    if [[ ! -d "$dir" ]]; then continue; fi
    chown root:apache "$dir"
    chmod ug+rwx,o-rwx "$dir"
done
for file in $(find "$LOG_DIR/httpd*" -type f -name '*log*' 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chown root:apache "$file"
    chmod ug+rw,ug-x,o-rwx "$file"
done

echo "Fixing MariaDB logging permissions"
chown mysql:mysql "$LOG_DIR/mariadb"
for file in $(find "$LOG_DIR/mariadb" -type f -name '*log*' 2>/dev/null); do
    if [[ ! -f "$file" ]]; then continue; fi
    chown mysql:mysql "$file"
    chmod ug+rw,ug-x,o-rwx "$file"
done

# Make sure MySQL is running for update.php. It is a chronic
# source of problems because the Linux OOM killer targets mysqld.
echo "Restarting MySQL"
systemctl stop mariadb.service 2>/dev/null
systemctl start mariadb.service

# Always run update script per https://www.mediawiki.org/wiki/Manual:Update.php
echo "Running update.php"
"${PHP_DIR}/php" "$WIKI_DIR/maintenance/update.php" --quick --server="https://www.cryptopp.com/wiki"

echo "Restarting Apache service"
if ! systemctl restart httpd24-httpd.service; then
    echo "Restart failed. Sleeping for 3 seconds"
    sleep 3
    echo "Restarting Apache service"
    systemctl stop httpd24-httpd.service 2>/dev/null
    systemctl start httpd24-httpd.service
fi

# Cleanup backup files
echo "Cleaning backup files"
find /var/www -name '*~' -exec rm {} \;
find /opt -name '*~' -exec rm {} \;
find /etc -name '*~' -exec rm {} \;

exit 0
