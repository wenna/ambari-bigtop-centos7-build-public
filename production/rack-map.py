#!/usr/bin/python3
import ipaddress
import socket
import sys

RACKS = {}


def rack(address):
    name = address.lower().rstrip(".")
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return RACKS.get(name, "/default-rack")
    try:
        return RACKS.get(socket.gethostbyaddr(name)[0].lower().rstrip("."), "/default-rack")
    except OSError:
        return "/default-rack"


if __name__ == "__main__":
    print(" ".join(rack(a) for a in sys.argv[1:]))
