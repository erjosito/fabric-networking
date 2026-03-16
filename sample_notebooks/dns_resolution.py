# Variable definiton
serverName = "<your_server_name>.database.windows.net"

# Try name resolution
try:
    import socket
    results = socket.getaddrinfo(serverName, None, socket.AF_UNSPEC)
    ipv4_addresses = []
    ipv6_addresses = []

    for result in results:
        family, _, _, _, sockaddr = result
        address = sockaddr[0]

        if family == socket.AF_INET:
            ipv4_addresses.append(address)
        elif family == socket.AF_INET6:
            ipv6_addresses.append(address)

    print(f"DNS information for '{serverName}':")
    print("IPv4 addresses:")
    for ipv4_address in ipv4_addresses:
        print(ipv4_address)
    print("IPv6 addresses:")
    for ipv6_address in ipv6_addresses:
        print(ipv6_address)
except socket.gaierror as e:
    print(f"Error: Unable to resolve '{serverName}': {e}")
