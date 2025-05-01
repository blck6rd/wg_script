# If system has a single IPv4, it is selected automatically. Else, ask the user
if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
    ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
else
    number_of_ip=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
    echo
    echo "Which IPv4 address should be used?"
    ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
    read -p "IPv4 address [1]: " ip_number
    until [[ -z "$ip_number" || "$ip_number" =~ ^[0-9]+$ && "$ip_number" -le "$number_of_ip" ]]; do
        echo "$ip_number: invalid selection."
        read -p "IPv4 address [1]: " ip_number
    done
    [[ -z "$ip_number" ]] && ip_number="1"
    ip=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ip_number"p)
fi

# Prompt user for the public endpoint (domain or IP)
echo
echo "Enter the public endpoint (domain or IP) clients will connect to:"
get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
read -p "Public endpoint [$get_public_ip]: " public_ip
until [[ -n "$public_ip" || -n "$get_public_ip" ]]; do
    echo "Invalid input."
    read -p "Public endpoint: " public_ip
done
[[ -z "$public_ip" ]] && public_ip="$get_public_ip"

# If $ip is a private IP address, inform the user about NAT setup (optional)
if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
    echo
    echo "Note: The server's local IP is private ($ip). Ensure the public endpoint ($public_ip) is correctly configured for NAT."
fi

# Rest of the script remains unchanged...