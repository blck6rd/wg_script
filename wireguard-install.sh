#!/bin/bash
#
# Modified WireGuard installer with GitHub backup integration
# Based on https://github.com/Nyr/wireguard-install
# Copyright (c) 2020 Nyr. Released under the MIT License.

# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
    echo 'This installer needs to be run with "bash", not "sh".'
    exit
fi

# Discard stdin
read -N 999999 -t 0.001

# Detect OS
if grep -qs "ubuntu" /etc/os-release; then
    os="ubuntu"
    os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
elif [[ -e /etc/debian_version ]]; then
    os="debian"
    os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
    os="centos"
    os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
elif [[ -e /etc/fedora-release ]]; then
    os="fedora"
    os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
else
    echo "This installer seems to be running on an unsupported distribution."
    exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 2204 ]]; then
    echo "Ubuntu 22.04 or higher is required."
    exit
fi

if [[ "$os" == "debian" ]]; then
    if grep -q '/sid' /etc/debian_version; then
        echo "Debian Testing and Debian Unstable are unsupported."
        exit
    fi
    if [[ "$os_version" -lt 11 ]]; then
        echo "Debian 11 or higher is required."
        exit
    fi
fi

if [[ "$os" == "centos" && "$os_version" -lt 9 ]]; then
    echo "CentOS 9 or higher is required."
    exit
fi

if ! grep -q sbin <<< "$PATH"; then
    echo '$PATH does not include sbin. Try using "su -" instead of "su".'
    exit
fi

# Detect if BoringTun needs to be used
if ! systemd-detect-virt -cq; then
    use_boringtun="0"
elif grep -q '^wireguard ' /proc/modules; then
    use_boringtun="0"
else
    use_boringtun="1"
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "This installer needs to be run with superuser privileges."
    exit
fi

if [[ "$use_boringtun" -eq 1 ]]; then
    if [ "$(uname -m)" != "x86_64" ]; then
        echo "BoringTun only supports x86_64 architecture."
        exit
    fi
    if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
        echo "TUN device not available."
        exit
    fi
fi

script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
clients_db="/etc/wireguard/clients.db"
backup_dir="/etc/wireguard/backups"
github_config="/etc/wireguard/github-backup.conf"

# ============================================
# GITHUB BACKUP FUNCTIONS
# ============================================

setup_github_backup() {
    echo
    echo "=== GitHub Backup Setup ==="
    echo
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        echo "Installing git..."
        if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            apt-get update && apt-get install -y git
        elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            dnf install -y git
        fi
    fi
    
    # Get server name
    echo "Enter a unique name for this server (e.g., server1, ny-vpn, london):"
    read -p "Server name: " server_name
    until [[ -n "$server_name" ]] && [[ "$server_name" =~ ^[a-zA-Z0-9_-]+$ ]]; do
        echo "Invalid name. Use only letters, numbers, hyphens and underscores."
        read -p "Server name: " server_name
    done
    
    # Get GitHub username
    echo
    read -p "Enter your GitHub username: " github_user
    until [[ -n "$github_user" ]]; do
        echo "Username cannot be empty."
        read -p "Enter your GitHub username: " github_user
    done
    
    # Get repository name
    echo
    read -p "Enter repository name [server-backups]: " repo_name
    [[ -z "$repo_name" ]] && repo_name="server-backups"
    
    # Setup SSH key
    echo
    echo "Setting up SSH key for GitHub..."
    ssh_key_path="/root/.ssh/github_backup_${server_name}"
    
    if [[ ! -f "$ssh_key_path" ]]; then
        ssh-keygen -t ed25519 -C "backup@${server_name}" -f "$ssh_key_path" -N ""
        echo
        echo "=========================================="
        echo "ADD THIS SSH KEY TO YOUR GITHUB ACCOUNT:"
        echo "=========================================="
        cat "${ssh_key_path}.pub"
        echo "=========================================="
        echo
        echo "Go to: https://github.com/settings/keys"
        echo "Click 'New SSH key'"
        echo "Title: ${server_name}-backup"
        echo "Key: (paste the key above)"
        echo
        read -p "Press Enter after you've added the key to GitHub..."
        
        # Test connection
        echo
        echo "Testing GitHub connection..."
        if ssh -i "$ssh_key_path" -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
            echo "✓ GitHub connection successful!"
        else
            echo "⚠ Warning: Could not verify GitHub connection."
            echo "Make sure you've added the SSH key correctly."
            read -p "Continue anyway? [y/N]: " continue_setup
            if [[ ! "$continue_setup" =~ ^[yY]$ ]]; then
                echo "Setup cancelled."
                return 1
            fi
        fi
    fi
    
    # Save configuration
    cat > "$github_config" << EOF
SERVER_NAME="$server_name"
GITHUB_USER="$github_user"
REPO_NAME="$repo_name"
SSH_KEY_PATH="$ssh_key_path"
BACKUP_BASE_DIR="/root/backups"
EOF
    
    chmod 600 "$github_config"
    
    # Initialize backup directory structure - IMPORTANT: Git repo at base level
    local backup_root="/root/backups"
    mkdir -p "$backup_root"
    
    cd "$backup_root" || exit 1
    
    # Initialize Git repository at BASE level (not in server subfolder)
    if [[ ! -d .git ]]; then
        git init
        git config user.email "backup@servers"
        git config user.name "Server Backups"
        git config core.sshCommand "ssh -i $ssh_key_path"
        
        echo "*.tmp" > .gitignore
        echo "# WireGuard Server Backups" > README.md
        echo "" >> README.md
        echo "This repository contains backups from multiple WireGuard servers." >> README.md
        echo "" >> README.md
        echo "## Servers:" >> README.md
        echo "- ${server_name}" >> README.md
        
        git add .gitignore README.md
        git commit -m "Initial commit"
        
        git branch -M main
        git remote add origin "git@github.com:${github_user}/${repo_name}.git"
        
        echo
        echo "Pushing initial commit to GitHub..."
        if git push -u origin main 2>/dev/null; then
            echo "✓ Initial push successful!"
        else
            echo "Note: If repository doesn't exist, create it first on GitHub:"
            echo "https://github.com/new"
            echo "Repository name: $repo_name"
            echo "Make it PRIVATE!"
            echo
            read -p "Press Enter after creating the repository..."
            git push -u origin main
        fi
    else
        # Repository already exists, just update README
        if ! grep -q "$server_name" README.md 2>/dev/null; then
            echo "- ${server_name}" >> README.md
            git add README.md
            git commit -m "Add ${server_name} to server list"
            git push origin main
        fi
    fi
    
    # Create server subdirectory structure
    mkdir -p "${server_name}"/{configs/root,configs/wireguard,logs,database}
    
    # Create backup script
    create_github_backup_script
    
    # Setup cron
    if ! crontab -l 2>/dev/null | grep -q 'wireguard-github-backup'; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/sbin/wireguard-github-backup >> /var/log/wireguard-backup.log 2>&1") | crontab -
        echo "✓ Cron job added (runs daily at 3:00 AM)"
    fi
    
    echo
    echo "=========================================="
    echo "✓ GitHub backup configured successfully!"
    echo "=========================================="
    echo "Server name: $server_name"
    echo "Backup location: $backup_root/$server_name"
    echo "GitHub: https://github.com/${github_user}/${repo_name}/tree/main/${server_name}"
    echo
    echo "Run manual backup: sudo /usr/local/sbin/wireguard-github-backup"
    echo
}

create_github_backup_script() {
    cat > /usr/local/sbin/wireguard-github-backup << 'EOFSCRIPT'
#!/bin/bash

# Load configuration
if [[ ! -f /etc/wireguard/github-backup.conf ]]; then
    echo "Error: GitHub backup not configured"
    exit 1
fi

source /etc/wireguard/github-backup.conf

# Work with BASE backup directory (where git repo is)
cd "${BACKUP_BASE_DIR}" || exit 1

# Ensure this is a git repository
if [[ ! -d .git ]]; then
    echo "Error: Not a git repository"
    exit 1
fi

DATE=$(date +%Y-%m-%d)
DAYS_TO_KEEP=90
SERVER_DIR="${BACKUP_BASE_DIR}/${SERVER_NAME}"

echo "=== Starting backup for ${SERVER_NAME} at $(date) ==="

# Create server directory structure if doesn't exist
mkdir -p "${SERVER_NAME}"/{configs/root,configs/wireguard,logs,database}

# 1. Backup all .conf files from /root
echo "Backing up .conf files from /root..."
find /root -name "*.conf" -type f -not -path "*/backups/*" 2>/dev/null | while read -r file; do
    cp "$file" "${SERVER_DIR}/configs/root/" 2>/dev/null
done

# 2. Backup main wg0.conf
echo "Backing up wg0.conf..."
if [[ -f /etc/wireguard/wg0.conf ]]; then
    cp /etc/wireguard/wg0.conf "${SERVER_DIR}/configs/wireguard/wg0.conf"
fi

# 3. Backup log file with date
echo "Backing up wireguard-expiry.log..."
if [[ -f /var/log/wireguard-expiry.log ]]; then
    cp /var/log/wireguard-expiry.log "${SERVER_DIR}/logs/wireguard-expiry-$DATE.log"
fi

# 4. Backup SQLite database with date
echo "Backing up clients.db..."
if [[ -f /etc/wireguard/clients.db ]]; then
    cp /etc/wireguard/clients.db "${SERVER_DIR}/database/clients-$DATE.db"
fi

# 5. Remove old backups (>90 days)
echo "Removing backups older than $DAYS_TO_KEEP days..."
find "${SERVER_DIR}/logs" -name "wireguard-expiry-*.log" -type f -mtime +$DAYS_TO_KEEP -delete 2>/dev/null
find "${SERVER_DIR}/database" -name "clients-*.db" -type f -mtime +$DAYS_TO_KEEP -delete 2>/dev/null

# 6. Git commit and push
echo "Committing to Git..."
git add "${SERVER_NAME}/"

if git diff --cached --quiet; then
    echo "No changes to commit"
else
    if git commit -m "WireGuard backup ${SERVER_NAME} - $DATE" 2>/dev/null; then
        echo "Pushing to GitHub..."
        GIT_SSH_COMMAND="ssh -i ${SSH_KEY_PATH}" git push origin main
        if [[ $? -eq 0 ]]; then
            echo "✓ Backup completed successfully at $(date)"
        else
            echo "✗ Error: Failed to push to GitHub"
            exit 1
        fi
    else
        echo "✗ Error: Failed to commit"
        exit 1
    fi
fi

echo "=== Backup finished ==="
EOFSCRIPT
    
    chmod +x /usr/local/sbin/wireguard-github-backup
    echo "✓ Backup script created"
}

test_github_backup() {
    if [[ ! -f "$github_config" ]]; then
        echo "GitHub backup not configured yet."
        return 1
    fi
    
    echo
    echo "Running test backup..."
    /usr/local/sbin/wireguard-github-backup
    
    if [[ $? -eq 0 ]]; then
        echo
        echo "✓ Test backup successful!"
        source "$github_config"
        echo "Check your GitHub repository: https://github.com/${GITHUB_USER}/${REPO_NAME}/tree/main/${SERVER_NAME}"
    else
        echo
        echo "✗ Test backup failed. Check the error messages above."
    fi
}

reconfigure_github_backup() {
    if [[ -f "$github_config" ]]; then
        echo
        echo "GitHub backup is already configured."
        source "$github_config"
        echo "Current server name: $SERVER_NAME"
        echo "Current repository: $GITHUB_USER/$REPO_NAME"
        echo
        read -p "Reconfigure? This will keep existing backups. [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[yY]$ ]]; then
            return
        fi
    fi
    
    setup_github_backup
}

# ============================================
# BACKUP SYSTEM (Local)
# ============================================

create_backup() {
    local backup_type=$1
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    mkdir -p "$backup_dir"
    
    case "$backup_type" in
        "wg0")
            if [[ -f /etc/wireguard/wg0.conf ]]; then
                cp /etc/wireguard/wg0.conf "$backup_dir/wg0.conf.$timestamp"
                echo "✓ Local backup: wg0.conf.$timestamp"
            fi
        ;;
        "db")
            if [[ -f "$clients_db" ]]; then
                cp "$clients_db" "$backup_dir/clients.db.$timestamp"
                echo "✓ Local backup: clients.db.$timestamp"
            fi
        ;;
        "all")
            if [[ -f /etc/wireguard/wg0.conf ]]; then
                cp /etc/wireguard/wg0.conf "$backup_dir/wg0.conf.$timestamp"
                echo "✓ Local backup: wg0.conf.$timestamp"
            fi
            if [[ -f "$clients_db" ]]; then
                cp "$clients_db" "$backup_dir/clients.db.$timestamp"
                echo "✓ Local backup: clients.db.$timestamp"
            fi
        ;;
    esac
    
    ls -t "$backup_dir"/wg0.conf.* 2>/dev/null | tail -n +31 | xargs -r rm -f
    ls -t "$backup_dir"/clients.db.* 2>/dev/null | tail -n +31 | xargs -r rm -f
}

# ============================================
# DATE FUNCTIONS (FIXED)
# ============================================

round_start_date() {
    local day=$(date +%d | sed 's/^0//')
    local month=$(date +%m)
    local year=$(date +%Y)
    
    # Определяем в какой период попадает текущая дата
    # 24-3: округляем к 1-му числу следующего периода
    # 4-13: округляем к 10-му числу
    # 14-23: округляем к 20-му числу
    
    if [[ $day -ge 24 ]]; then
        # С 24-го до конца месяца -> 1-е число следующего месяца
        if [[ "$month" == "12" ]]; then
            echo "$((year + 1))-01-01"
        else
            next_month=$(printf "%02d" $((10#$month + 1)))
            echo "${year}-${next_month}-01"
        fi
    elif [[ $day -le 3 ]]; then
        # С 1-го по 3-е -> 1-е число текущего месяца
        echo "${year}-${month}-01"
    elif [[ $day -ge 4 ]] && [[ $day -le 13 ]]; then
        # С 4-го по 13-е -> 10-е число
        echo "${year}-${month}-10"
    elif [[ $day -ge 14 ]] && [[ $day -le 23 ]]; then
        # С 14-го по 23-е -> 20-е число
        echo "${year}-${month}-20"
    fi
}

calculate_end_date() {
    local start_date=$1
    local months=$2
    date -d "$start_date + $months months" +%Y-%m-%d
}

# Calculate days until expiry
days_until_expiry() {
    local end_date=$1
    local today=$(date +%Y-%m-%d)
    
    # Convert dates to seconds since epoch
    local end_seconds=$(date -d "$end_date" +%s)
    local today_seconds=$(date -d "$today" +%s)
    
    # Calculate difference in days
    local diff_seconds=$((end_seconds - today_seconds))
    local diff_days=$((diff_seconds / 86400))
    
    echo "$diff_days"
}

# ============================================
# SUBSCRIPTION EXTENSION FUNCTION (NEW)
# ============================================

extend_subscription() {
    if [[ ! -f "$clients_db" ]]; then
        echo "База данных не найдена!"
        return 1
    fi
    
    echo
    echo "=== Продление подписки ==="
    echo
    echo "Выберите режим отображения:"
    echo "   1) Истекающие (≤2 дня) и отключённые профили"
    echo "   2) Все профили"
    echo "   3) Вернуться в главное меню"
    read -p "Выбор [1]: " display_mode
    until [[ -z "$display_mode" || "$display_mode" =~ ^[1-3]$ ]]; do
        echo "$display_mode: неверный выбор."
        read -p "Выбор [1]: " display_mode
    done
    [[ -z "$display_mode" ]] && display_mode="1"
    
    if [[ "$display_mode" == "3" ]]; then
        return 0
    fi
    
    # Build list of profiles to display
    local profiles_to_show=""
    local counter=1
    
    echo
    if [[ "$display_mode" == "1" ]]; then
        echo "Профили, требующие продления (истекают ≤2 дня или отключены):"
        echo "============================================================="
    else
        echo "Все профили:"
        echo "============="
    fi
    echo
    
    # Header
    printf "   %-3s %-20s | %-16s | %-10s | %-12s | %-12s | %-10s\n" \
           "#" "Имя" "Телефон" "Статус" "Начало" "Окончание" "Осталось"
    printf "   %-3s %-20s | %-16s | %-10s | %-12s | %-12s | %-10s\n" \
           "---" "--------------------" "----------------" "----------" "------------" "------------" "----------"
    
    # Build the list
    local temp_list="/tmp/wg_extend_list.tmp"
    > "$temp_list"
    
    while IFS='|' read -r client phone start_date end_date status disabled_date; do
        local show_this=0
        local days_left="N/A"
        
        if [[ "$status" == "active" ]]; then
            days_left=$(days_until_expiry "$end_date")
            if [[ "$display_mode" == "1" ]]; then
                # Show only if expiring soon
                if [[ $days_left -le 2 ]]; then
                    show_this=1
                fi
            else
                # Show all
                show_this=1
            fi
        elif [[ "$status" == "disabled" ]]; then
            days_left="Disabled"
            if [[ "$display_mode" == "1" ]] || [[ "$display_mode" == "2" ]]; then
                show_this=1
            fi
        fi
        
        if [[ $show_this -eq 1 ]]; then
            echo "$counter|$client|$phone|$start_date|$end_date|$status|$days_left" >> "$temp_list"
            
            # Format status for display
            local display_status="$status"
            if [[ "$status" == "active" ]]; then
                display_status="АКТИВЕН"
            elif [[ "$status" == "disabled" ]]; then
                display_status="ОТКЛЮЧЁН"
            fi
            
            # Color coding for days left
            local days_display="$days_left"
            if [[ "$days_left" != "Disabled" ]] && [[ "$days_left" != "N/A" ]]; then
                if [[ $days_left -le 0 ]]; then
                    days_display="ИСТЁК"
                elif [[ $days_left -le 2 ]]; then
                    days_display="$days_left дн."
                else
                    days_display="$days_left дн."
                fi
            elif [[ "$days_left" == "Disabled" ]]; then
                days_display="Отключён"
            fi
            
            printf "   %-3d %-20s | %-16s | %-10s | %-12s | %-12s | %-10s\n" \
                   "$counter" "$client" "$phone" "$display_status" "$start_date" "$end_date" "$days_display"
            ((counter++))
        fi
    done < "$clients_db"
    
    local total_count=$((counter - 1))
    
    if [[ $total_count -eq 0 ]]; then
        echo "Профили по выбранным критериям не найдены."
        rm -f "$temp_list"
        return 0
    fi
    
    echo
    read -p "Выберите профиль для продления [0 - отмена]: " selection
    until [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -le "$total_count" ]]; do
        echo "$selection: неверный выбор."
        read -p "Выберите профиль [0 - отмена]: " selection
    done
    
    if [[ "$selection" -eq 0 ]]; then
        rm -f "$temp_list"
        echo "Продление отменено."
        return 0
    fi
    
    # Get selected client info
    local selected_line=$(sed -n "${selection}p" "$temp_list")
    local selected_client=$(echo "$selected_line" | cut -d'|' -f2)
    local selected_phone=$(echo "$selected_line" | cut -d'|' -f3)
    local selected_status=$(echo "$selected_line" | cut -d'|' -f6)
    local old_start=$(echo "$selected_line" | cut -d'|' -f4)
    local old_end=$(echo "$selected_line" | cut -d'|' -f5)
    
    rm -f "$temp_list"
    
    echo
    echo "Выбран: $selected_client"
    echo "Телефон: $selected_phone"
    echo "Текущий статус: $selected_status"
    if [[ "$selected_status" == "active" ]]; then
        echo "Текущий период: $old_start — $old_end"
    fi
    
    echo
    read -p "Срок продления в месяцах [1]: " duration_months
    until [[ -z "$duration_months" || "$duration_months" =~ ^[0-9]+$ ]]; do
        echo "$duration_months: неверный ввод."
        read -p "Срок в месяцах [1]: " duration_months
    done
    [[ -z "$duration_months" ]] && duration_months="1"
    
    # Calculate new dates
    local today=$(date +%Y-%m-%d)
    local new_start_date
    local new_end_date
    
    if [[ "$selected_status" == "active" ]] && [[ "$old_end" < "$today" ]]; then
        # Профиль истёк, но активен - новый период от старой даты окончания
        new_start_date="$old_end"
        new_end_date=$(calculate_end_date "$new_start_date" "$duration_months")
    elif [[ "$selected_status" == "active" ]] && [[ ! "$old_end" < "$today" ]]; then
        # Профиль активен и НЕ истёк - просто добавляем время к текущему end_date
        new_start_date="$old_start"
        new_end_date=$(calculate_end_date "$old_end" "$duration_months")
    else
        # Отключённый профиль - начинаем от текущей даты (округлённой)
        new_start_date=$(round_start_date)
        new_end_date=$(calculate_end_date "$new_start_date" "$duration_months")
    fi
    
    echo
    echo "Новый период подписки:"
    echo "Начало: $new_start_date"
    echo "Окончание: $new_end_date"
    echo
    read -p "Подтвердить продление? [y/N]: " confirm
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Продление отменено."
        return 0
    fi
    
    # Create backup before changes
    echo "Создание резервной копии..."
    create_backup "all"
    
    # Process based on current status
    if [[ "$selected_status" == "disabled" ]]; then
        # Re-enable the client
        echo "Включение клиента..."
        sed -i "/^# DISABLED # # BEGIN_PEER $selected_client$/,/^# DISABLED # # END_PEER $selected_client$/s/^# DISABLED # //" /etc/wireguard/wg0.conf
        wg addconf wg0 <(sed -n "/^# BEGIN_PEER $selected_client$/,/^# END_PEER $selected_client$/p" /etc/wireguard/wg0.conf)
    fi
    
    # Update database with new dates and active status
    local temp_db="${clients_db}.tmp"
    > "$temp_db"
    
    while IFS='|' read -r client phone start_date end_date status disabled_date; do
        if [[ "$client" == "$selected_client" ]]; then
            echo "$client|$phone|$new_start_date|$new_end_date|active|" >> "$temp_db"
        else
            echo "$client|$phone|$start_date|$end_date|$status|$disabled_date" >> "$temp_db"
        fi
    done < "$clients_db"
    
    mv "$temp_db" "$clients_db"
    
    echo
    echo "✓ Подписка успешно продлена!"
    echo "Клиент: $selected_client"
    echo "Новый период: $new_start_date — $new_end_date"
    echo "Статус: АКТИВЕН"
}

# ============================================
# DATABASE FUNCTIONS (UPDATED)
# ============================================

add_client_to_db() {
    local client=$1
    local phone=$2
    local start_date=$3
    local end_date=$4
    local status=$5
    local disabled_date=${6:-""}  # Дата отключения (опциональная)
    echo "$client|$phone|$start_date|$end_date|$status|$disabled_date" >> "$clients_db"
}

update_client_status() {
    local client=$1
    local status=$2
    local end_date=$3
    
    # При отключении добавляем текущую дату как дату отключения
    if [[ "$status" == "disabled" ]]; then
        local disabled_date=$(date +%Y-%m-%d)
        if [[ -n "$end_date" ]]; then
            local phone=$(grep "^$client|" "$clients_db" | cut -d'|' -f2)
            local start_date=$(grep "^$client|" "$clients_db" | cut -d'|' -f3)
            sed -i "s/^$client|.*$/$client|$phone|$start_date|$end_date|$status|$disabled_date/" "$clients_db"
        else
            # Обновляем существующую запись, добавляя дату отключения
            local existing=$(grep "^$client|" "$clients_db")
            local phone=$(echo "$existing" | cut -d'|' -f2)
            local start_date=$(echo "$existing" | cut -d'|' -f3)
            local end_date_existing=$(echo "$existing" | cut -d'|' -f4)
            sed -i "s/^$client|.*$/$client|$phone|$start_date|$end_date_existing|$status|$disabled_date/" "$clients_db"
        fi
    else
        # При активации убираем дату отключения
        if [[ -n "$end_date" ]]; then
            local phone=$(grep "^$client|" "$clients_db" | cut -d'|' -f2)
            local start_date=$(grep "^$client|" "$clients_db" | cut -d'|' -f3)
            sed -i "s/^$client|.*$/$client|$phone|$start_date|$end_date|$status|/" "$clients_db"
        else
            sed -i "s/^\($client|[^|]*|[^|]*|[^|]*\)|[^|]*|.*$/\1|$status|/" "$clients_db"
        fi
    fi
}

get_client_info() {
    local client=$1
    grep "^$client|" "$clients_db"
}

# Миграция базы данных для добавления поля disabled_date
migrate_database() {
    if [[ ! -f "$clients_db" ]]; then
        return
    fi
    
    # Проверяем, нужна ли миграция (если в строках меньше 6 полей)
    local needs_migration=0
    while IFS='|' read -r line; do
        local field_count=$(echo "$line" | awk -F'|' '{print NF}')
        if [[ $field_count -lt 6 ]]; then
            needs_migration=1
            break
        fi
    done < "$clients_db"
    
    if [[ $needs_migration -eq 1 ]]; then
        echo "Migrating database to new format..."
        local temp_db="${clients_db}.tmp"
        > "$temp_db"
        
        while IFS='|' read -r client phone start_date end_date status rest; do
            # Добавляем пустое поле для disabled_date
            echo "$client|$phone|$start_date|$end_date|$status|" >> "$temp_db"
        done < "$clients_db"
        
        mv "$temp_db" "$clients_db"
        echo "Database migration completed."
    fi
}

# ============================================
# CLEANUP FUNCTIONS (NEW)
# ============================================

cleanup_old_disabled_profiles() {
    if [[ ! -f "$clients_db" ]]; then
        return
    fi
    
    local today=$(date +%Y-%m-%d)
    local ten_days_ago=$(date -d "10 days ago" +%Y-%m-%d)
    local changes_made=0
    
    while IFS='|' read -r client phone start_date end_date status disabled_date; do
        if [[ "$status" == "disabled" ]] && [[ -n "$disabled_date" ]] && [[ "$disabled_date" < "$ten_days_ago" ]]; then
            if [[ "$changes_made" -eq 0 ]]; then
                echo "Создание резервной копии перед очисткой..."
                create_backup "all"
                changes_made=1
            fi
            
            echo "Удаление старого отключённого профиля: $client (отключён: $disabled_date)"
            
            # Удаляем из wg0.conf
            sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
            sed -i "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/d" /etc/wireguard/wg0.conf
            
            # Удаляем из базы данных
            sed -i "/^$client|/d" "$clients_db"
            
            # Удаляем конфигурационный файл
            rm -f "$script_dir"/"$client.conf"
            
            echo "$(date): Удалён старый отключённый клиент $client (отключён: $disabled_date)" >> /var/log/wireguard-expiry.log
        fi
    done < "$clients_db"
}

# ============================================
# CLIENT MANAGEMENT FUNCTIONS (UPDATED)
# ============================================

check_expired_profiles() {
    if [[ ! -f "$clients_db" ]]; then
        return
    fi
    
    local today=$(date +%Y-%m-%d)
    
    while IFS='|' read -r client phone start_date end_date status disabled_date; do
        if [[ "$status" == "active" ]] && [[ "$end_date" < "$today" ]]; then
            echo "Отключение истёкшего профиля: $client (истёк: $end_date)"
            disable_client "$client"
        fi
    done < "$clients_db"
    
    # Также запускаем очистку старых отключенных профилей
    cleanup_old_disabled_profiles
}

disable_client() {
    local client=$1
    
    echo "Создание резервной копии перед отключением клиента..."
    create_backup "all"
    
    wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" /etc/wireguard/wg0.conf | grep -m 1 PublicKey | cut -d " " -f 3)" remove 2>/dev/null
    sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/s/^/# DISABLED # /" /etc/wireguard/wg0.conf
    update_client_status "$client" "disabled"
}

enable_client() {
    local client=$1
    
    echo "Создание резервной копии перед включением клиента..."
    create_backup "all"
    
    sed -i "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/s/^# DISABLED # //" /etc/wireguard/wg0.conf
    wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/p" /etc/wireguard/wg0.conf)
    update_client_status "$client" "active"
}

# Функция для получения всех занятых IP (конфиг + runtime)
get_occupied_ips() {
    local occupied_ips=()
    
    # Активные IP из конфига
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && occupied_ips+=("$ip")
    done < <(grep "^AllowedIPs" /etc/wireguard/wg0.conf | cut -d "." -f 4 | cut -d "/" -f 1)
    
    # Отключенные IP из конфига
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && occupied_ips+=("$ip")
    done < <(grep "^# DISABLED # AllowedIPs" /etc/wireguard/wg0.conf | cut -d "." -f 4 | cut -d "/" -f 1)
    
    # Runtime IP (на случай рассинхрона конфига и wg)
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && occupied_ips+=("$ip")
    done < <(wg show wg0 allowed-ips 2>/dev/null | awk '{print $2}' | cut -d'.' -f4 | cut -d'/' -f1)
    
    # Убираем дубликаты и выводим
    printf '%s\n' "${occupied_ips[@]}" | sort -u
}

# Проверка, свободен ли IP
is_ip_free() {
    local octet=$1
    local occupied_ips
    occupied_ips=$(get_occupied_ips)
    
    if echo "$occupied_ips" | grep -qx "$octet"; then
        return 1  # занят
    fi
    return 0  # свободен
}

# Поиск свободного IP с учетом отключенных профилей и runtime
find_free_ip() {
    local octet=2
    local occupied_ips
    occupied_ips=$(get_occupied_ips)
    
    # Ищем первый свободный IP
    while echo "$occupied_ips" | grep -qx "$octet"; do
        (( octet++ ))
        if [[ "$octet" -eq 255 ]]; then
            echo "253 клиента уже настроено. Подсеть заполнена!" >&2
            return 1
        fi
    done
    
    echo "$octet"
}
# ============================================
# IP CHANGE FUNCTION (IMPROVED)
# ============================================

change_client_ip() {
    local client=$1
    
    # Проверяем существование клиента
    if ! grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf && \
       ! grep -q "^# DISABLED # # BEGIN_PEER $client$" /etc/wireguard/wg0.conf; then
        echo "Клиент $client не найден!"
        return 1
    fi
    
    # Получаем информацию о клиенте из БД
    local client_info=$(get_client_info "$client")
    if [[ -z "$client_info" ]]; then
        echo "Клиент не найден в базе данных!"
        return 1
    fi
    
    local phone=$(echo "$client_info" | cut -d'|' -f2)
    local start_date=$(echo "$client_info" | cut -d'|' -f3)
    local end_date=$(echo "$client_info" | cut -d'|' -f4)
    local status=$(echo "$client_info" | cut -d'|' -f5)
    
    echo "Клиент: $client"
    echo "Телефон: $phone"
    echo "Статус: $status"
    echo "Текущая подписка: $start_date — $end_date"
    echo
    
    # Получаем текущий IP клиента
    local current_ip=""
    if [[ "$status" == "active" ]]; then
        current_ip=$(sed -n "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/p" /etc/wireguard/wg0.conf | grep "^AllowedIPs" | cut -d "." -f 4 | cut -d "/" -f 1)
    else
        current_ip=$(sed -n "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/p" /etc/wireguard/wg0.conf | grep "^# DISABLED # AllowedIPs" | sed 's/^# DISABLED # //' | cut -d "." -f 4 | cut -d "/" -f 1)
    fi
    
    echo "Текущий IP: 10.7.0.$current_ip"
    
    # Находим свободный IP автоматически
    local new_octet=$(find_free_ip)
    if [[ $? -ne 0 ]]; then
        echo "Не удалось найти свободный IP!"
        return 1
    fi
    
    echo "Новый IP: 10.7.0.$new_octet"
    echo
    read -p "Подтвердить смену IP? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo "Смена IP отменена."
        return 0
    fi
    
    # Проверяем наличие конфига клиента
    if [[ ! -f "$script_dir/$client.conf" ]]; then
        echo "Ошибка: Конфигурационный файл клиента не найден!"
        return 1
    fi
    
    # Создаем бэкап ПЕРЕД любыми изменениями
    echo "Создание резервной копии..."
    create_backup "all"
    local backup_wg0="/tmp/wg0.conf.backup.$$"
    cp /etc/wireguard/wg0.conf "$backup_wg0"
    
    # Извлекаем приватный ключ клиента
    local client_private_key=$(grep "^PrivateKey" "$script_dir/$client.conf" | cut -d "=" -f 2- | tr -d ' ')
    if [[ -z "$client_private_key" ]]; then
        echo "Ошибка: Не удалось извлечь приватный ключ клиента!"
        rm -f "$backup_wg0"
        return 1
    fi
    
    # Вычисляем публичный ключ из приватного (надёжнее, чем парсить конфиг)
    local client_public_key=$(echo "$client_private_key" | wg pubkey)
    if [[ -z "$client_public_key" ]]; then
        echo "Ошибка: Не удалось вычислить публичный ключ!"
        rm -f "$backup_wg0"
        return 1
    fi
    
    # Получаем preshared key из серверного конфига
    local preshared_key=""
    if [[ "$status" == "active" ]]; then
        preshared_key=$(sed -n "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/p" /etc/wireguard/wg0.conf | grep "^PresharedKey" | cut -d "=" -f 2- | tr -d ' ')
    else
        preshared_key=$(sed -n "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/p" /etc/wireguard/wg0.conf | grep "^# DISABLED # PresharedKey" | sed 's/^# DISABLED # //' | cut -d "=" -f 2- | tr -d ' ')
    fi
    
    # Проверка наличия IPv6
    local ipv6_config=""
    local ipv6_client=""
    if grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf; then
        ipv6_config=", fddd:2c4:2c4:2c4::$new_octet/128"
        ipv6_client=", fddd:2c4:2c4:2c4::$new_octet/64"
    fi
    
    # === АТОМАРНОЕ ОБНОВЛЕНИЕ ===
    # Удаляем старый peer из конфига
    if [[ "$status" == "active" ]]; then
        # Сначала удаляем из runtime
        wg set wg0 peer "$client_public_key" remove 2>/dev/null
        # Затем из конфига
        sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
    else
        sed -i "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/d" /etc/wireguard/wg0.conf
    fi
    
    # Добавляем новую конфигурацию peer
    if [[ "$status" == "active" ]]; then
        cat << EOF >> /etc/wireguard/wg0.conf
# BEGIN_PEER $client
[Peer]
PublicKey = $client_public_key
PresharedKey = $preshared_key
AllowedIPs = 10.7.0.$new_octet/32$ipv6_config
# END_PEER $client
EOF
        # Применяем изменения с проверкой
        if ! wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/p" /etc/wireguard/wg0.conf) 2>/dev/null; then
            echo "Ошибка применения конфигурации! Восстанавливаю бэкап..."
            cp "$backup_wg0" /etc/wireguard/wg0.conf
            wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null
            rm -f "$backup_wg0"
            return 1
        fi
    else
        cat << EOF >> /etc/wireguard/wg0.conf
# DISABLED # # BEGIN_PEER $client
# DISABLED # [Peer]
# DISABLED # PublicKey = $client_public_key
# DISABLED # PresharedKey = $preshared_key
# DISABLED # AllowedIPs = 10.7.0.$new_octet/32$ipv6_config
# DISABLED # # END_PEER $client
EOF
    fi
    
    # Получаем DNS настройки из старого конфига
    local dns="8.8.8.8, 8.8.4.4"
    if [[ -f "$script_dir/$client.conf" ]]; then
        dns=$(grep "^DNS" "$script_dir/$client.conf" | cut -d "=" -f 2 | sed 's/^ *//;s/ *$//')
        dns=$(echo "$dns" | sed 's/,/, /g' | sed 's/,  /, /g')
    fi
    
    # Получаем публичный ключ сервера
    local server_public_key=$(grep "^PrivateKey" /etc/wireguard/wg0.conf | cut -d " " -f 3 | wg pubkey)
    
    # Получаем endpoint
    local endpoint=$(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3)
    local listen_port=$(grep "^ListenPort" /etc/wireguard/wg0.conf | cut -d " " -f 3)
    
    # Создаем новый конфиг клиента
    cat << EOF > "$script_dir/$client.conf"
[Interface]
Address = 10.7.0.$new_octet/24$ipv6_client
DNS = $dns
PrivateKey = $client_private_key

[Peer]
PublicKey = $server_public_key
PresharedKey = $preshared_key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $endpoint:$listen_port
PersistentKeepalive = 25
EOF
    
    # Логируем изменение
    echo "$(date '+%Y-%m-%d %H:%M:%S'): IP изменён для $client: 10.7.0.$current_ip -> 10.7.0.$new_octet" >> /var/log/wireguard-changes.log
    
    # Очистка
    rm -f "$backup_wg0"
    
    echo
    echo "✓ IP-адрес успешно изменён!"
    echo "Старый IP: 10.7.0.$current_ip"
    echo "Новый IP: 10.7.0.$new_octet"
    echo
    echo "Новая конфигурация сохранена в: $script_dir/$client.conf"
    echo
    echo "QR-код для новой конфигурации:"
    qrencode -t ANSI256UTF8 < "$script_dir/$client.conf"
}

new_client_dns() {
    echo "Выберите DNS-сервер для клиента:"
    echo "   1) Системные DNS по умолчанию"
    echo "   2) Google"
    echo "   3) 1.1.1.1"
    echo "   4) OpenDNS"
    echo "   5) Quad9"
    echo "   6) Gcore"
    echo "   7) AdGuard"
    echo "   8) Указать свой DNS"
    read -p "DNS-сервер [1]: " dns
    until [[ -z "$dns" || "$dns" =~ ^[1-8]$ ]]; do
        echo "$dns: неверный выбор."
        read -p "DNS-сервер [1]: " dns
    done
    case "$dns" in
        1|"")
            if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
                resolv_conf="/etc/resolv.conf"
            else
                resolv_conf="/run/systemd/resolve/resolv.conf"
            fi
            dns=$(grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | xargs | sed -e 's/ /, /g')
        ;;
        2)
            dns="8.8.8.8, 8.8.4.4"
        ;;
        3)
            dns="1.1.1.1, 1.0.0.1"
        ;;
        4)
            dns="208.67.222.222, 208.67.220.220"
        ;;
        5)
            dns="9.9.9.9, 149.112.112.112"
        ;;
        6)
            dns="95.85.95.85, 2.56.220.2"
        ;;
        7)
            dns="94.140.14.14, 94.140.15.15"
        ;;
        8)
            echo
            until [[ -n "$custom_dns" ]]; do
                echo "Введите DNS-серверы (IPv4, через запятую или пробел):"
                read -p "DNS-серверы: " dns_input
                dns_input=$(echo "$dns_input" | tr ',' ' ')
                for dns_ip in $dns_input; do
                    if [[ "$dns_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        if [[ -z "$custom_dns" ]]; then
                            custom_dns="$dns_ip"
                        else
                            custom_dns="$custom_dns, $dns_ip"
                        fi
                    fi
                done
                if [ -z "$custom_dns" ]; then
                    echo "Неверный ввод."
                else
                    dns="$custom_dns"
                fi
            done
        ;;
    esac
}

new_client_setup() {
    # Используем новую функцию поиска свободного IP
    octet=$(find_free_ip)
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    echo
    read -p "Введите номер телефона (например, +79288888888): " phone_number
    until [[ -n "$phone_number" ]]; do
        echo "Номер телефона не может быть пустым."
        read -p "Введите номер телефона: " phone_number
    done
    
    echo
    read -p "Введите срок подписки в месяцах [1]: " duration_months
    until [[ -z "$duration_months" || "$duration_months" =~ ^[0-9]+$ ]]; do
        echo "$duration_months: неверный ввод."
        read -p "Введите срок в месяцах [1]: " duration_months
    done
    [[ -z "$duration_months" ]] && duration_months="1"
    
    start_date=$(round_start_date)
    end_date=$(calculate_end_date "$start_date" "$duration_months")
    
    echo "Телефон: $phone_number"
    echo "Дата начала: $start_date"
    echo "Дата окончания: $end_date"
    
    echo
    echo "Создание резервной копии перед добавлением клиента..."
    create_backup "all"
    
    key=$(wg genkey)
    psk=$(wg genpsk)
    
    cat << EOF >> /etc/wireguard/wg0.conf
# BEGIN_PEER $client
[Peer]
PublicKey = $(wg pubkey <<< $key)
PresharedKey = $psk
AllowedIPs = 10.7.0.$octet/32$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/128")
# END_PEER $client
EOF
    
    cat << EOF > "$script_dir"/"$client".conf
[Interface]
Address = 10.7.0.$octet/24$(grep -q 'fddd:2c4:2c4:2c4::1' /etc/wireguard/wg0.conf && echo ", fddd:2c4:2c4:2c4::$octet/64")
DNS = $dns
PrivateKey = $key

[Peer]
PublicKey = $(grep PrivateKey /etc/wireguard/wg0.conf | cut -d " " -f 3 | wg pubkey)
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $(grep '^# ENDPOINT' /etc/wireguard/wg0.conf | cut -d " " -f 3):$(grep ListenPort /etc/wireguard/wg0.conf | cut -d " " -f 3)
PersistentKeepalive = 25
EOF
    
    add_client_to_db "$client" "$phone_number" "$start_date" "$end_date" "active" ""
}

setup_expiry_check() {
    cat << 'EOF' > /usr/local/sbin/wg-check-expiry
#!/bin/bash
clients_db="/etc/wireguard/clients.db"
backup_dir="/etc/wireguard/backups"
today=$(date +%Y-%m-%d)
ten_days_ago=$(date -d "10 days ago" +%Y-%m-%d)

if [[ ! -f "$clients_db" ]]; then
    exit 0
fi

create_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$backup_dir"
    
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        cp /etc/wireguard/wg0.conf "$backup_dir/wg0.conf.$timestamp"
    fi
    if [[ -f "$clients_db" ]]; then
        cp "$clients_db" "$backup_dir/clients.db.$timestamp"
    fi
    
    ls -t "$backup_dir"/wg0.conf.* 2>/dev/null | tail -n +31 | xargs -r rm -f
    ls -t "$backup_dir"/clients.db.* 2>/dev/null | tail -n +31 | xargs -r rm -f
}

changes_made=0

# Проверка истекших подписок
while IFS='|' read -r client phone start_date end_date status disabled_date; do
    if [[ "$status" == "active" ]] && [[ "$end_date" < "$today" ]]; then
        if [[ "$changes_made" -eq 0 ]]; then
            create_backup
            changes_made=1
        fi
        
        wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" /etc/wireguard/wg0.conf | grep -m 1 PublicKey | cut -d " " -f 3)" remove 2>/dev/null
        sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/s/^/# DISABLED # /" /etc/wireguard/wg0.conf
        
        # Обновляем статус и добавляем дату отключения
        local disabled_date_now=$(date +%Y-%m-%d)
        sed -i "s/^$client|$phone|$start_date|$end_date|active|.*$/$client|$phone|$start_date|$end_date|disabled|$disabled_date_now/" "$clients_db"
        
        echo "$(date): Disabled expired client $client" >> /var/log/wireguard-expiry.log
    fi
    
    # Удаление профилей, отключенных более 10 дней назад
    if [[ "$status" == "disabled" ]] && [[ -n "$disabled_date" ]] && [[ "$disabled_date" < "$ten_days_ago" ]]; then
        if [[ "$changes_made" -eq 0 ]]; then
            create_backup
            changes_made=1
        fi
        
        # Удаляем из wg0.conf
        sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
        sed -i "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/d" /etc/wireguard/wg0.conf
        
        # Удаляем из базы данных
        sed -i "/^$client|/d" "$clients_db"
        
        # Удаляем конфигурационный файл
        rm -f "/root/$client.conf"
        
        echo "$(date): Removed old disabled client $client (disabled: $disabled_date)" >> /var/log/wireguard-expiry.log
    fi
done < "$clients_db"
EOF
    
    chmod +x /usr/local/sbin/wg-check-expiry
    
    if ! crontab -l 2>/dev/null | grep -q 'wg-check-expiry'; then
        (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/sbin/wg-check-expiry") | crontab -
    fi
}

display_clients_list() {
    local filter=$1
    local counter=1
    
    if [[ ! -f "$clients_db" ]]; then
        grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3 | while read -r client; do
            echo "   $counter) $client"
            ((counter++))
        done
        return
    fi
    
    printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "#" "Name" "Phone" "Start Date" "End Date"
    printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "---" "--------------------" "----------------" "------------" "------------"
    
    while IFS='|' read -r client phone start_date end_date status disabled_date; do
        if [[ "$filter" == "all" ]] || [[ "$filter" == "$status" ]]; then
            printf "   %-3d %-20s | %-16s | %-12s | %-12s\n" "$counter" "$client" "$phone" "$start_date" "$end_date"
            ((counter++))
        fi
    done < "$clients_db"
}

# ============================================
# INSTALLATION
# ============================================

if [[ ! -e /etc/wireguard/wg0.conf ]]; then
    if ! hash wget 2>/dev/null && ! hash curl 2>/dev/null; then
        echo "Требуется Wget."
        read -n1 -r -p "Нажмите любую клавишу, чтобы установить Wget..."
        apt-get update
        apt-get install -y wget
    fi
    clear
    echo 'Установка Wireguard!'
    
    number_of_ip=$(ip -4 addr | grep inet | grep -v '127\.' | wc -l)
    if [[ "$number_of_ip" -eq 1 ]]; then
        ip=$(ip -4 addr | grep inet | grep -v '127\.' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
    else
        echo
        echo "Какой IPv4 адрес следует использовать?"
        ip -4 addr | grep inet | grep -v '127\.' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | nl -s ") "
        read -p "IPv4 адрес [1]: " ip_number
        until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
            echo "$ip_number: неверный выбор."
            read -p "IPv4 адрес [1]: " ip_number
        done
        [[ -z "$ip_number" ]] && ip_number="1"
        ip=$(ip -4 addr | grep inet | grep -v '127\.' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sed -n "$ip_number"p)
    fi
    
    if echo "$ip" | grep -qE '^10\.|^172\.1[6789]\.|^172\.2[0-9]\.|^172\.3[01]\.|^192\.168'; then
        echo
        echo "Этот сервер находится за NAT. Какой у него публичный IPv4-адрес или имя хоста?"
        public_ip_raw=$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" 2>/dev/null || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/" 2>/dev/null)
        get_public_ip=$(echo "$public_ip_raw" | grep -m 1 -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')
        read -p "Публичный IPv4 адрес / имя хоста [$get_public_ip]: " public_ip
        until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
            echo "Invalid input."
            read -p "Публичный IPv4 адрес / имя хоста: " public_ip
        done
        [[ -z "$public_ip" ]] && public_ip="$get_public_ip"
    fi
    
    if [[ -z "$public_ip" ]]; then
        echo
        echo "Настроить конечную точку:"
        echo "   1) Использовать IP сервера ($ip)"
        echo "   2) Введите пользовательский домен/IP"
        read -p "Вариант конечной точки [1]: " endpoint_option
        until [[ -z "$endpoint_option" || "$endpoint_option" =~ ^[1-2]$ ]]; do
            echo "$endpoint_option: неверный выбор."
            read -p "Вариант конечной точки [1]: " endpoint_option
        done
        
        if [[ "$endpoint_option" == "2" ]]; then
            read -p "Введите пользовательскую конечную точку: " custom_endpoint
            until [[ -n "$custom_endpoint" ]]; do
                echo "Неверный выбор."
                read -p "Введите пользовательскую конечную точку: " custom_endpoint
            done
            public_ip="$custom_endpoint"
        fi
    fi
    
    ipv6_count=$(ip -6 addr | grep -c 'inet6 [23]')
    if [[ "$ipv6_count" -eq 1 ]]; then
        ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | awk '{print $2}')
    fi
    if [[ "$ipv6_count" -gt 1 ]]; then
        echo
        echo "Какой IPv6 адрес следует использовать?"
        ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | awk '{print $2}' | nl -s ") "
        read -p "IPv6 адрес [1]: " ip6_number
        until [[ -z "$ip6_number" || "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -le "$ipv6_count" ]]; do
            echo "$ip6_number: неверный выбор."
            read -p "IPv6 адрес [1]: " ip6_number
        done
        [[ -z "$ip6_number" ]] && ip6_number="1"
        ip6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | awk '{print $2}' | sed -n "$ip6_number"p)
    fi
    
    echo
    echo "Какой порт должен прослушивать WireGuard?"
    read -p "Порт [51820]: " port
    until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
        echo "$port: неверный порт."
        read -p "Порт [51820]: " port
    done
    [[ -z "$port" ]] && port="51820"
    
    echo
    echo "Введите имя для первого клиента:"
    read -p "Имя [client]: " unsanitized_client
    client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client" | cut -c-25)
    [[ -z "$client" ]] && client="client"
    
    echo
    new_client_dns
    
    if [[ "$use_boringtun" -eq 1 ]]; then
        echo
        echo "BoringTun будет установлен."
        read -p "Включить автоматические обновления? [Y/n]: " boringtun_updates
        until [[ "$boringtun_updates" =~ ^[yYnN]*$ ]]; do
            read -p "Включить автоматические обновления? [Y/n]: " boringtun_updates
        done
        [[ -z "$boringtun_updates" ]] && boringtun_updates="y"
        if [[ "$boringtun_updates" =~ ^[yY]$ ]]; then
            if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
                cron="cronie"
            elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
                cron="cron"
            fi
        fi
    fi
    
    echo
    echo "Установка WireGuard готова."
    if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
        if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            firewall="firewalld"
            echo "firewalld также будет установлен."
        elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
            firewall="iptables"
        fi
    fi
    read -n1 -r -p "Нажмите любую клавишу, чтобы продолжить..."
    
    if [[ "$use_boringtun" -eq 0 ]]; then
        if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            apt-get update
            apt-get install -y wireguard qrencode $firewall
        elif [[ "$os" == "centos" ]]; then
            dnf install -y epel-release
            dnf install -y wireguard-tools qrencode $firewall
        elif [[ "$os" == "fedora" ]]; then
            dnf install -y wireguard-tools qrencode $firewall
            mkdir -p /etc/wireguard/
        fi
    else
        if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
            apt-get update
            apt-get install -y qrencode ca-certificates $cron $firewall
            apt-get install -y wireguard-tools --no-install-recommends
        elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            dnf install -y epel-release
            dnf install -y wireguard-tools qrencode ca-certificates tar $cron $firewall
            mkdir -p /etc/wireguard/
        fi
        { wget -qO- https://wg.nyr.be/1/latest/download 2>/dev/null || curl -sL https://wg.nyr.be/1/latest/download ; } | tar xz -C /usr/local/sbin/ --wildcards 'boringtun-*/boringtun' --strip-components 1
        mkdir /etc/systemd/system/wg-quick@wg0.service.d/ 2>/dev/null
        echo "[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=boringtun
Environment=WG_SUDO=1" > /etc/systemd/system/wg-quick@wg0.service.d/boringtun.conf
        if [[ -n "$cron" ]] && [[ "$os" == "centos" || "$os" == "fedora" ]]; then
            systemctl enable --now crond.service
        fi
    fi
    
    if [[ "$firewall" == "firewalld" ]]; then
        systemctl enable --now firewalld.service
    fi
    
    cat << EOF > /etc/wireguard/wg0.conf
# Do not alter the commented lines
# ENDPOINT $([[ -n "$public_ip" ]] && echo "$public_ip" || echo "$ip")

[Interface]
Address = 10.7.0.1/24$([[ -n "$ip6" ]] && echo ", fddd:2c4:2c4:2c4::1/64")
PrivateKey = $(wg genkey)
ListenPort = $port

EOF
    chmod 600 /etc/wireguard/wg0.conf
    
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-forward.conf
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if [[ -n "$ip6" ]]; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-wireguard-forward.conf
        echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    fi
    
    if systemctl is-active --quiet firewalld.service; then
        firewall-cmd --add-port="$port"/udp
        firewall-cmd --zone=trusted --add-source=10.7.0.0/24
        firewall-cmd --permanent --add-port="$port"/udp
        firewall-cmd --permanent --zone=trusted --add-source=10.7.0.0/24
        firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$ip"
        firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$ip"
        if [[ -n "$ip6" ]]; then
            firewall-cmd --zone=trusted --add-source=fddd:2c4:2c4:2c4::/64
            firewall-cmd --permanent --zone=trusted --add-source=fddd:2c4:2c4:2c4::/64
            firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
            firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
        fi
    else
        iptables_path=$(command -v iptables)
        ip6tables_path=$(command -v ip6tables)
        if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
            iptables_path=$(command -v iptables-legacy)
            ip6tables_path=$(command -v ip6tables-legacy)
        fi
        echo "[Unit]
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$iptables_path -w 5 -t nat -A POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to $ip
ExecStart=$iptables_path -w 5 -I INPUT -p udp --dport $port -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStart=$iptables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -w 5 -t nat -D POSTROUTING -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to $ip
ExecStop=$iptables_path -w 5 -D INPUT -p udp --dport $port -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -s 10.7.0.0/24 -j ACCEPT
ExecStop=$iptables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/wg-iptables.service
        if [[ -n "$ip6" ]]; then
            echo "ExecStart=$ip6tables_path -w 5 -t nat -A POSTROUTING -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to $ip6
ExecStart=$ip6tables_path -w 5 -I FORWARD -s fddd:2c4:2c4:2c4::/64 -j ACCEPT
ExecStart=$ip6tables_path -w 5 -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -w 5 -t nat -D POSTROUTING -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to $ip6
ExecStop=$ip6tables_path -w 5 -D FORWARD -s fddd:2c4:2c4:2c4::/64 -j ACCEPT
ExecStop=$ip6tables_path -w 5 -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/wg-iptables.service
        fi
        echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/wg-iptables.service
        systemctl enable --now wg-iptables.service
    fi
    
    touch "$clients_db"
    new_client_setup
    setup_expiry_check
    systemctl enable --now wg-quick@wg0.service
    
    if [[ "$boringtun_updates" =~ ^[yY]$ ]]; then
        cat << 'EOF' > /usr/local/sbin/boringtun-upgrade
#!/bin/bash
latest=$(wget -qO- https://wg.nyr.be/1/latest 2>/dev/null || curl -sL https://wg.nyr.be/1/latest 2>/dev/null)
if ! head -1 <<< "$latest" | grep -qiE "^boringtun.+[0-9]+\.[0-9]+.*$"; then
    exit
fi
current=$(/usr/local/sbin/boringtun -V)
if [[ "$current" != "$latest" ]]; then
    download="https://wg.nyr.be/1/latest/download"
    xdir=$(mktemp -d)
    if { wget -qO- "$download" 2>/dev/null || curl -sL "$download" ; } | tar xz -C "$xdir" --wildcards "boringtun-*/boringtun" --strip-components 1; then
        systemctl stop wg-quick@wg0.service
        rm -f /usr/local/sbin/boringtun
        mv "$xdir"/boringtun /usr/local/sbin/boringtun
        systemctl start wg-quick@wg0.service
    fi
    rm -rf "$xdir"
fi
EOF
        chmod +x /usr/local/sbin/boringtun-upgrade
        { crontab -l 2>/dev/null; echo "$(( $RANDOM % 60 )) $(( $RANDOM % 3 + 3 )) * * * /usr/local/sbin/boringtun-upgrade &>/dev/null" ; } | crontab -
    fi
    
    echo
    echo "Создание первоначальной локальной резервной копии..."
    create_backup "all"
    echo
    
    # Ask about GitHub backup setup
    echo
    echo "==================================="
    echo "Хотите ли вы настроить автоматическое резервное копирование GitHub??"
    echo "Это позволит создать резервную копию ваших конфигураций в репозитории GitHub.."
    read -p "Настроить резервное копирование GitHub? [Y/n]: " setup_github
    until [[ "$setup_github" =~ ^[yYnN]*$ ]]; do
        read -p "Настроить резервное копирование GitHub? [Y/n]: " setup_github
    done
    [[ -z "$setup_github" ]] && setup_github="y"
    
    if [[ "$setup_github" =~ ^[yY]$ ]]; then
        setup_github_backup
        echo
        echo "Запуск первоначального резервного копирования GitHub..."
        /usr/local/sbin/wireguard-github-backup
    else
        echo
        echo "Вы можете настроить резервное копирование GitHub позже, выполнив команду:"
        echo "sudo $0 --configure-github"
    fi
    
    echo
    qrencode -t ANSI256UTF8 < "$script_dir"/"$client.conf"
    echo -e '\n↑ QR-код для настройки клиента'
    echo
    echo "=========================================="
    echo "✓ Установка WireGuard завершена!"
    echo "=========================================="
    echo "Конфигурация клиента: $script_dir/$client.conf"
    if [[ -f "$clients_db" ]]; then
        client_info=$(get_client_info "$client")
        echo "Номер: $(echo "$client_info" | cut -d'|' -f2)"
        echo "Дата начала: $(echo "$client_info" | cut -d'|' -f3)"
        echo "Дата конца: $(echo "$client_info" | cut -d'|' -f4)"
    fi
    echo
    echo "Локальные резервные копии: $backup_dir"
    if [[ -f "$github_config" ]]; then
        source "$github_config"
        echo "Резервные копии GitHub: https://github.com/${GITHUB_USER}/${REPO_NAME}/tree/main/${SERVER_NAME}"
    fi
    echo
    echo "Запустите этот скрипт еще раз для управления клиентами и резервными копиями.."
else
    # Handle command line arguments
    if [[ "$1" == "--configure-github" ]]; then
        setup_github_backup
        exit
    elif [[ "$1" == "--test-backup" ]]; then
        test_github_backup
        exit
    fi
    
    # Мигрируем базу данных при необходимости
    migrate_database
    
    # ============================================
    # MANAGEMENT MENU
    # ============================================
    clear
    echo "WireGuard уже установлен."
    echo
    
    # Show GitHub backup status
    if [[ -f "$github_config" ]]; then
        source "$github_config"
        echo "✓ GitHub бэкап: https://github.com/${GITHUB_USER}/${REPO_NAME}/tree/main/${SERVER_NAME}"
        echo
    fi
    
    echo "Выберите действие:"
    echo "   1) Добавить нового клиента"
    echo "   2) Удалить клиента"
    echo "   3) Отключить клиента вручную"
    echo "   4) Включить отключённого клиента"
    echo "   5) Список активных клиентов"
    echo "   6) Список отключённых клиентов"
    echo "   7) Показать QR-код клиента"
    echo "   8) Проверить истёкшие профили"
    echo "   9) Продлить подписку"
    echo "   10) Изменить IP-адрес клиента"
    echo "   11) Управление локальными бэкапами"
    echo "   12) Настройки GitHub бэкапа"
    echo "   13) Удалить WireGuard"
    echo "   14) Выход"
    read -p "Выбор: " option
    until [[ "$option" =~ ^([1-9]|1[0-4])$ ]]; do
        echo "$option: неверный выбор."
        read -p "Выбор: " option
    done
    case "$option" in
        1)
            echo
            echo "Введите имя для клиента:"
            read -p "Имя: " unsanitized_client
            client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client" | cut -c-25)
            while [[ -z "$client" ]] || grep -q "^# BEGIN_PEER $client$" /etc/wireguard/wg0.conf; do
                echo "$client: недопустимое имя."
                read -p "Имя: " unsanitized_client
                client=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client" | cut -c-25)
            done
            echo
            new_client_dns
            new_client_setup
            wg addconf wg0 <(sed -n "/^# BEGIN_PEER $client/,/^# END_PEER $client/p" /etc/wireguard/wg0.conf)
            echo
            qrencode -t ANSI256UTF8 < "$script_dir"/"$client.conf"
            echo -e '\n↑ QR-код для клиента'
            echo
            echo "$client добавлен: $script_dir/$client.conf"
            if [[ -f "$clients_db" ]]; then
                client_info=$(get_client_info "$client")
                echo "Телефон: $(echo "$client_info" | cut -d'|' -f2)"
                echo "Начало: $(echo "$client_info" | cut -d'|' -f3)"
                echo "Окончание: $(echo "$client_info" | cut -d'|' -f4)"
            fi
            exit
        ;;
        2)
            number_of_clients=$(grep -c '^# BEGIN_PEER' /etc/wireguard/wg0.conf)
            if [[ "$number_of_clients" = 0 ]]; then
                echo
                echo "Нет клиентов!"
                exit
            fi
            echo
            echo "Выберите клиента для удаления:"
            display_clients_list "all"
            
            # Подсчитываем общее количество клиентов в БД (если есть) или в конфиге
            if [[ -f "$clients_db" ]]; then
                total_clients=$(wc -l < "$clients_db")
            else
                total_clients=$number_of_clients
            fi
            
            read -p "Клиент: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$total_clients" ]]; do
                echo "$client_number: неверный выбор."
                read -p "Клиент: " client_number
            done
            
            # Выбираем клиента из отображённого списка
            if [[ -f "$clients_db" ]]; then
                # Если есть БД, выбираем из неё
                counter=1
                while IFS='|' read -r client_name phone start_date end_date status disabled_date; do
                    if [[ $counter -eq $client_number ]]; then
                        client=$client_name
                        break
                    fi
                    ((counter++))
                done < "$clients_db"
            else
                # Если БД нет, используем старую логику
                client=$(grep '^# BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3 | sed -n "$client_number"p)
            fi
            echo
            read -p "Подтвердить удаление $client? [y/N]: " remove
            until [[ "$remove" =~ ^[yYnN]*$ ]]; do
                echo "$remove: неверный ввод."
                read -p "Подтвердить удаление $client? [y/N]: " remove
            done
            if [[ "$remove" =~ ^[yY]$ ]]; then
                echo
                echo "Создание резервной копии перед удалением..."
                create_backup "all"
                wg set wg0 peer "$(sed -n "/^# BEGIN_PEER $client$/,\$p" /etc/wireguard/wg0.conf | grep -m 1 PublicKey | cut -d " " -f 3)" remove 2>/dev/null
                sed -i "/^# BEGIN_PEER $client$/,/^# END_PEER $client$/d" /etc/wireguard/wg0.conf
                sed -i "/^# DISABLED # # BEGIN_PEER $client$/,/^# DISABLED # # END_PEER $client$/d" /etc/wireguard/wg0.conf
                sed -i "/^$client|/d" "$clients_db"
                rm -f "$script_dir"/"$client.conf"
                echo
                echo "$client удалён!"
            else
                echo
                echo "Удаление отменено."
            fi
            exit
        ;;
        3)
            if [[ ! -f "$clients_db" ]]; then
                echo "База данных не найдена!"
                exit
            fi
            
            active_count=$(grep '|active' "$clients_db" | wc -l)
            if [[ "$active_count" -eq 0 ]]; then
                echo
                echo "Нет активных клиентов!"
                exit
            fi
            
            echo
            echo "Выберите клиента для отключения:"
            printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "#" "Имя" "Телефон" "Начало" "Окончание"
            printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "---" "----" "-----" "-----" "---"
            counter=1
            while IFS='|' read -r client phone start_date end_date status disabled_date; do
                if [[ "$status" == "active" ]]; then
                    printf "   %-3d %-20s | %-16s | %-12s | %-12s\n" "$counter" "$client" "$phone" "$start_date" "$end_date"
                    ((counter++))
                fi
            done < "$clients_db"
            
            read -p "Клиент: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$active_count" ]]; do
                echo "$client_number: неверный выбор."
                read -p "Клиент: " client_number
            done
            
            counter=1
            while IFS='|' read -r client phone start_date end_date status disabled_date; do
                if [[ "$status" == "active" ]]; then
                    if [[ $counter -eq $client_number ]]; then
                        selected_client=$client
                        break
                    fi
                    ((counter++))
                fi
            done < "$clients_db"
            
            echo
            read -p "Подтвердить отключение $selected_client? [y/N]: " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                disable_client "$selected_client"
                echo
                echo "$selected_client отключён!"
            else
                echo
                echo "Отключение отменено."
            fi
            exit
        ;;
        4)
            if [[ ! -f "$clients_db" ]]; then
                echo "База данных не найдена!"
                exit
            fi
            
            disabled_count=$(grep '|disabled' "$clients_db" | wc -l)
            if [[ "$disabled_count" -eq 0 ]]; then
                echo
                echo "Нет отключённых клиентов!"
                exit
            fi
            
            echo
            echo "Выберите клиента для включения:"
            printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "#" "Имя" "Телефон" "Начало" "Окончание"
            printf "   %-3s %-20s | %-16s | %-12s | %-12s\n" "---" "----" "-----" "-----" "---"
            counter=1
            while IFS='|' read -r client phone start_date end_date status disabled_date; do
                if [[ "$status" == "disabled" ]]; then
                    printf "   %-3d %-20s | %-16s | %-12s | %-12s\n" "$counter" "$client" "$phone" "$start_date" "$end_date"
                    ((counter++))
                fi
            done < "$clients_db"
            
            read -p "Клиент: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$disabled_count" ]]; do
                echo "$client_number: неверный выбор."
                read -p "Клиент: " client_number
            done
            
            counter=1
            while IFS='|' read -r client phone start_date end_date status disabled_date; do
                if [[ "$status" == "disabled" ]]; then
                    if [[ $counter -eq $client_number ]]; then
                        selected_client=$client
                        break
                    fi
                    ((counter++))
                fi
            done < "$clients_db"
            
            echo
            read -p "Срок подписки (месяцев) [1]: " duration_months
            until [[ -z "$duration_months" || "$duration_months" =~ ^[0-9]+$ ]]; do
                echo "$duration_months: неверный ввод."
                read -p "Срок (месяцев) [1]: " duration_months
            done
            [[ -z "$duration_months" ]] && duration_months="1"
            
            start_date=$(round_start_date)
            end_date=$(calculate_end_date "$start_date" "$duration_months")
            
            echo "Новое начало: $start_date"
            echo "Новое окончание: $end_date"
            
            enable_client "$selected_client"
            update_client_status "$selected_client" "active" "$end_date"
            
            echo
            echo "$selected_client включён!"
            exit
        ;;
        5)
            if [[ ! -f "$clients_db" ]]; then
                echo "База данных не найдена!"
                exit
            fi
            
            echo
            echo "Активные клиенты:"
            echo "================="
            echo
            
            if ! grep -q '|active' "$clients_db"; then
                echo "Нет активных клиентов."
            else
                printf "%-20s | %-16s | %-12s | %-12s\n" "Имя" "Телефон" "Начало" "Окончание"
                printf "%-20s | %-16s | %-12s | %-12s\n" "----" "-----" "-----" "---"
                while IFS='|' read -r client phone start_date end_date status disabled_date; do
                    if [[ "$status" == "active" ]]; then
                        printf "%-20s | %-16s | %-12s | %-12s\n" "$client" "$phone" "$start_date" "$end_date"
                    fi
                done < "$clients_db"
            fi
            exit
        ;;
        6)
            if [[ ! -f "$clients_db" ]]; then
                echo "База данных не найдена!"
                exit
            fi
            
            echo
            echo "Отключённые клиенты:"
            echo "===================="
            echo
            
            if ! grep -q '|disabled' "$clients_db"; then
                echo "Нет отключённых клиентов."
            else
                printf "%-20s | %-16s | %-12s | %-12s | %-12s\n" "Имя" "Телефон" "Начало" "Окончание" "Отключён"
                printf "%-20s | %-16s | %-12s | %-12s | %-12s\n" "----" "-----" "-----" "---" "--------"
                while IFS='|' read -r client phone start_date end_date status disabled_date; do
                    if [[ "$status" == "disabled" ]]; then
                        printf "%-20s | %-16s | %-12s | %-12s | %-12s\n" "$client" "$phone" "$start_date" "$end_date" "$disabled_date"
                    fi
                done < "$clients_db"
            fi
            exit
        ;;
        7)
            echo
            echo "Доступные клиенты:"
            display_clients_list "all"
            
            # Подсчитываем общее количество клиентов в БД или конфиге
            if [[ -f "$clients_db" ]]; then
                total_clients=$(wc -l < "$clients_db")
            else
                total_clients=$(grep -c '^# BEGIN_PEER' /etc/wireguard/wg0.conf)
                total_clients=$((total_clients + $(grep -c '^# DISABLED # # BEGIN_PEER' /etc/wireguard/wg0.conf)))
            fi
            
            if [[ "$total_clients" -eq 0 ]]; then
                echo "Клиенты не найдены!"
                exit
            fi
            
            read -p "Выберите клиента: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$total_clients" ]]; do
                echo "$client_number: неверный выбор."
                read -p "Выберите клиента: " client_number
            done
            
            # Находим клиента из списка
            if [[ -f "$clients_db" ]]; then
                # Если есть БД, выбираем из неё
                counter=1
                client_name=""
                while IFS='|' read -r client phone start_date end_date status disabled_date; do
                    if [[ $counter -eq $client_number ]]; then
                        client_name=$client
                        break
                    fi
                    ((counter++))
                done < "$clients_db"
            else
                # Если БД нет, используем старую логику с конфигом
                client_name=$(grep '^# BEGIN_PEER\|^# DISABLED # # BEGIN_PEER' /etc/wireguard/wg0.conf | cut -d ' ' -f 3,5 | sed 's/ //g' | sed -n "${client_number}p")
            fi
            
            if [[ -f "$script_dir/$client_name.conf" ]]; then
                echo
                qrencode -t ANSI256UTF8 < "$script_dir/$client_name.conf"
                echo -e '\n↑ QR-код для: '"$client_name"
                
                if [[ -f "$clients_db" ]] && grep -q "^$client_name|" "$clients_db"; then
                    client_info=$(get_client_info "$client_name")
                    echo
                    echo "Информация о клиенте:"
                    echo "Телефон: $(echo "$client_info" | cut -d'|' -f2)"
                    echo "Начало: $(echo "$client_info" | cut -d'|' -f3)"
                    echo "Окончание: $(echo "$client_info" | cut -d'|' -f4)"
                    echo "Статус: $(echo "$client_info" | cut -d'|' -f5)"
                fi
            else
                echo "Конфигурация не найдена: $client_name"
            fi
            exit
        ;;
        8)
            echo
            echo "Проверка истёкших профилей..."
            check_expired_profiles
            echo "Проверка завершена!"
            exit
        ;;
        9)
            # New menu item - Extend subscription
            extend_subscription
            exit
        ;;
        10)
            # IP address change (previously 9)
            if [[ ! -f "$clients_db" ]]; then
                echo "База данных не найдена!"
                exit
            fi
            
            total_clients=$(grep -c '|' "$clients_db")
            if [[ "$total_clients" -eq 0 ]]; then
                echo
                echo "Нет клиентов!"
                exit
            fi
            
            echo
            echo "Выберите клиента для смены IP-адреса:"
            display_clients_list "all"
            
            read -p "Клиент: " client_number
            until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$total_clients" ]]; do
                echo "$client_number: неверный выбор."
                read -p "Клиент: " client_number
            done
            
            counter=1
            while IFS='|' read -r client phone start_date end_date status disabled_date; do
                if [[ $counter -eq $client_number ]]; then
                    selected_client=$client
                    break
                fi
                ((counter++))
            done < "$clients_db"
            
            echo
            change_client_ip "$selected_client"
            exit
        ;;
        11)
            # Local backup management (previously 10)
            echo
            echo "=== Управление локальными бэкапами ==="
            echo
            echo "Выберите действие:"
            echo "   1) Список всех бэкапов"
            echo "   2) Восстановить из бэкапа"
            echo "   3) Создать бэкап вручную"
            echo "   4) Удалить старые бэкапы"
            echo "   5) Вернуться в главное меню"
            read -p "Выбор: " backup_option
            until [[ "$backup_option" =~ ^[1-5]$ ]]; do
                echo "$backup_option: неверный выбор."
                read -p "Выбор: " backup_option
            done
            
            case "$backup_option" in
                1)
                    echo
                    echo "Доступные локальные бэкапы:"
                    echo "==========================="
                    echo
                    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
                        echo "Бэкапы не найдены."
                    else
                        echo "Бэкапы конфигурации WireGuard:"
                        ls -lh "$backup_dir"/wg0.conf.* 2>/dev/null | awk '{print $9, "(" $5 ", " $6, $7, $8 ")"}' | sed 's|.*/||'
                        echo
                        echo "Бэкапы базы данных:"
                        ls -lh "$backup_dir"/clients.db.* 2>/dev/null | awk '{print $9, "(" $5 ", " $6, $7, $8 ")"}' | sed 's|.*/||'
                    fi
                ;;
                2)
                    echo
                    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
                        echo "Бэкапы недоступны."
                        exit
                    fi
                    
                    echo "Выберите файл для восстановления:"
                    echo "   1) wg0.conf"
                    echo "   2) clients.db"
                    echo "   3) Оба файла"
                    read -p "Файл [3]: " restore_file
                    until [[ -z "$restore_file" || "$restore_file" =~ ^[1-3]$ ]]; do
                        echo "$restore_file: неверный выбор."
                        read -p "Файл [3]: " restore_file
                    done
                    [[ -z "$restore_file" ]] && restore_file="3"
                    
                    if [[ "$restore_file" == "1" ]] || [[ "$restore_file" == "3" ]]; then
                        echo
                        echo "Доступные бэкапы wg0.conf:"
                        ls -1t "$backup_dir"/wg0.conf.* 2>/dev/null | nl -s ") "
                        backup_count=$(ls -1 "$backup_dir"/wg0.conf.* 2>/dev/null | wc -l)
                        
                        if [[ "$backup_count" -eq 0 ]]; then
                            echo "Бэкапы wg0.conf отсутствуют."
                        else
                            read -p "Выберите бэкап: " wg_backup_num
                            until [[ "$wg_backup_num" =~ ^[0-9]+$ && "$wg_backup_num" -le "$backup_count" ]]; do
                                echo "$wg_backup_num: неверный выбор."
                                read -p "Выберите бэкап: " wg_backup_num
                            done
                            wg_backup_file=$(ls -1t "$backup_dir"/wg0.conf.* | sed -n "${wg_backup_num}p")
                            
                            create_backup "wg0"
                            
                            cp "$wg_backup_file" /etc/wireguard/wg0.conf
                            systemctl restart wg-quick@wg0.service
                            echo "wg0.conf восстановлен из $wg_backup_file"
                        fi
                    fi
                    
                    if [[ "$restore_file" == "2" ]] || [[ "$restore_file" == "3" ]]; then
                        echo
                        echo "Доступные бэкапы clients.db:"
                        ls -1t "$backup_dir"/clients.db.* 2>/dev/null | nl -s ") "
                        backup_count=$(ls -1 "$backup_dir"/clients.db.* 2>/dev/null | wc -l)
                        
                        if [[ "$backup_count" -eq 0 ]]; then
                            echo "Бэкапы clients.db отсутствуют."
                        else
                            read -p "Выберите бэкап: " db_backup_num
                            until [[ "$db_backup_num" =~ ^[0-9]+$ && "$db_backup_num" -le "$backup_count" ]]; do
                                echo "$db_backup_num: неверный выбор."
                                read -p "Выберите бэкап: " db_backup_num
                            done
                            db_backup_file=$(ls -1t "$backup_dir"/clients.db.* | sed -n "${db_backup_num}p")
                            
                            create_backup "db"
                            
                            cp "$db_backup_file" "$clients_db"
                            echo "clients.db восстановлен из $db_backup_file"
                        fi
                    fi
                ;;
                3)
                    echo
                    echo "Создание бэкапа вручную..."
                    create_backup "all"
                    echo "Бэкап создан!"
                ;;
                4)
                    echo
                    if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
                        echo "Нет бэкапов для удаления."
                    else
                        echo "Удалить бэкапы старше скольки дней?"
                        read -p "Дней [30]: " days_old
                        until [[ -z "$days_old" || "$days_old" =~ ^[0-9]+$ ]]; do
                            echo "$days_old: неверный ввод."
                            read -p "Дней [30]: " days_old
                        done
                        [[ -z "$days_old" ]] && days_old="30"
                        
                        deleted_count=$(find "$backup_dir" -type f -mtime +$days_old 2>/dev/null | wc -l)
                        if [[ "$deleted_count" -eq 0 ]]; then
                            echo "Нет бэкапов старше $days_old дней."
                        else
                            echo "Найдено $deleted_count бэкап(ов) старше $days_old дней."
                            read -p "Подтвердить удаление? [y/N]: " confirm_delete
                            if [[ "$confirm_delete" =~ ^[yY]$ ]]; then
                                find "$backup_dir" -type f -mtime +$days_old -delete
                                echo "Старые бэкапы удалены."
                            else
                                echo "Удаление отменено."
                            fi
                        fi
                    fi
                ;;
                5)
                    exec "$0"
                ;;
            esac
            exit
        ;;
        12)
            # GitHub backup management (previously 11)
            echo
            echo "=== Настройки GitHub бэкапа ==="
            echo
            echo "Выберите действие:"
            echo "   1) Настроить GitHub бэкап"
            echo "   2) Проверить подключение"
            echo "   3) Запустить бэкап вручную"
            echo "   4) Статус бэкапа"
            echo "   5) Вернуться в главное меню"
            read -p "Выбор: " github_option
            until [[ "$github_option" =~ ^[1-5]$ ]]; do
                echo "$github_option: неверный выбор."
                read -p "Выбор: " github_option
            done
            
            case "$github_option" in
                1)
                    reconfigure_github_backup
                ;;
                2)
                    test_github_backup
                ;;
                3)
                    if [[ ! -f "$github_config" ]]; then
                        echo "GitHub бэкап не настроен."
                        echo "Сначала выполните настройку (пункт 1)."
                    else
                        echo
                        echo "Запуск бэкапа вручную..."
                        /usr/local/sbin/wireguard-github-backup
                    fi
                ;;
                4)
                    if [[ ! -f "$github_config" ]]; then
                        echo
                        echo "GitHub бэкап не настроен."
                    else
                        source "$github_config"
                        echo
                        echo "=== Статус бэкапа ==="
                        echo "Имя сервера: $SERVER_NAME"
                        echo "Репозиторий: https://github.com/${GITHUB_USER}/${REPO_NAME}"
                        echo "Путь бэкапа: ${BACKUP_BASE_DIR}/${SERVER_NAME}"
                        echo "Просмотр на GitHub: https://github.com/${GITHUB_USER}/${REPO_NAME}/tree/main/${SERVER_NAME}"
                        echo
                        if [[ -d "${BACKUP_BASE_DIR}/.git" ]]; then
                            cd "${BACKUP_BASE_DIR}"
                            last_commit=$(git log -1 --format="%cd" --date=format:"%Y-%m-%d %H:%M:%S" 2>/dev/null)
                            if [[ -n "$last_commit" ]]; then
                                echo "Последний бэкап: $last_commit"
                            fi
                        fi
                        echo
                        echo "Расписание cron:"
                        crontab -l 2>/dev/null | grep wireguard-github-backup
                    fi
                ;;
                5)
                    exec "$0"
                ;;
            esac
            exit
        ;;
        13)
            echo
            read -p "Подтвердить удаление WireGuard? [y/N]: " remove
            until [[ "$remove" =~ ^[yYnN]*$ ]]; do
                echo "$remove: неверный ввод."
                read -p "Подтвердить удаление? [y/N]: " remove
            done
            if [[ "$remove" =~ ^[yY]$ ]]; then
                port=$(grep '^ListenPort' /etc/wireguard/wg0.conf | cut -d " " -f 3)
                if systemctl is-active --quiet firewalld.service; then
                    ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep -s '10.7.0.0/24' | awk '{print $NF}')
                    firewall-cmd --remove-port="$port"/udp
                    firewall-cmd --zone=trusted --remove-source=10.7.0.0/24
                    firewall-cmd --permanent --remove-port="$port"/udp
                    firewall-cmd --permanent --zone=trusted --remove-source=10.7.0.0/24
                    firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$ip"
                    firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.7.0.0/24 ! -d 10.7.0.0/24 -j SNAT --to "$ip"
                    if grep -qs 'fddd:2c4:2c4:2c4::1/64' /etc/wireguard/wg0.conf; then
                        ip6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep -s 'fddd:2c4:2c4:2c4::/64' | awk '{print $NF}')
                        firewall-cmd --zone=trusted --remove-source=fddd:2c4:2c4:2c4::/64
                        firewall-cmd --permanent --zone=trusted --remove-source=fddd:2c4:2c4:2c4::/64
                        firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
                        firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:2c4:2c4:2c4::/64 ! -d fddd:2c4:2c4:2c4::/64 -j SNAT --to "$ip6"
                    fi
                else
                    systemctl disable --now wg-iptables.service
                    rm -f /etc/systemd/system/wg-iptables.service
                fi
                systemctl disable --now wg-quick@wg0.service
                rm -f /etc/systemd/system/wg-quick@wg0.service.d/boringtun.conf
                rm -f /etc/sysctl.d/99-wireguard-forward.conf
                
                (crontab -l 2>/dev/null | grep -v 'wg-check-expiry\|wireguard-github-backup') | crontab - 2>/dev/null
                rm -f /usr/local/sbin/wg-check-expiry
                rm -f /usr/local/sbin/wireguard-github-backup
                
                if [[ "$use_boringtun" -eq 0 ]]; then
                    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
                        rm -rf /etc/wireguard/
                        apt-get remove --purge -y wireguard wireguard-tools
                    elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
                        dnf remove -y wireguard-tools
                        rm -rf /etc/wireguard/
                    fi
                else
                    (crontab -l 2>/dev/null | grep -v '/usr/local/sbin/boringtun-upgrade') | crontab - 2>/dev/null
                    if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
                        rm -rf /etc/wireguard/
                        apt-get remove --purge -y wireguard-tools
                    elif [[ "$os" == "centos" || "$os" == "fedora" ]]; then
                        dnf remove -y wireguard-tools
                        rm -rf /etc/wireguard/
                    fi
                    rm -f /usr/local/sbin/boringtun /usr/local/sbin/boringtun-upgrade
                fi
                echo
                echo "WireGuard удалён!"
                echo "Примечание: GitHub бэкапы и локальные бэкапы НЕ были удалены."
            else
                echo
                echo "Удаление отменено."
            fi
            exit
        ;;
        14)
            exit
        ;;
    esac
fi
