#!/usr/bin/env python3
"""
replay_seed.py — Replay an AFLNet seed file to a UDP server

AFLNet stores network sessions as a sequence of:
  [4-byte big-endian length][payload bytes]
  [4-byte big-endian length][payload bytes]
  ...

This script reads such a file and sends each message as a separate
UDP datagram, with a configurable inter-packet delay.

Usage:
  python3 replay_seed.py <seed_file> <host> <port> [delay_ms]

Examples:
  python3 replay_seed.py seeds/full_session.raw 127.0.0.1 1234
  python3 replay_seed.py seeds/reg_only.raw 127.0.0.1 9999 50
"""

import sys
import socket
import struct
import time
import os


def replay_seed(path: str, host: str, port: int, delay_ms: int = 20):
    """Send all messages from an AFLNet seed file to host:port via UDP."""
    if not os.path.isfile(path):
        print(f"[!] File not found: {path}", file=sys.stderr)
        return 0

    data = open(path, 'rb').read()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)

    sent = 0
    offset = 0

    while offset + 4 <= len(data):
        # Read 4-byte big-endian message length
        msg_len = struct.unpack_from('>I', data, offset)[0]
        offset += 4

        if msg_len == 0:
            continue

        if offset + msg_len > len(data):
            # Truncated message — send what we have
            payload = data[offset:]
        else:
            payload = data[offset:offset + msg_len]

        offset += msg_len

        if len(payload) == 0:
            continue

        try:
            sock.sendto(payload, (host, port))
            sent += 1
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)
        except OSError as e:
            print(f"[!] Send error: {e}", file=sys.stderr)
            break

    sock.close()
    return sent


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)

    path  = sys.argv[1]
    host  = sys.argv[2]
    port  = int(sys.argv[3])
    delay = int(sys.argv[4]) if len(sys.argv) > 4 else 20

    n = replay_seed(path, host, port, delay)
    if n > 0:
        print(f"[+] Sent {n} packet(s) from {os.path.basename(path)}")


if __name__ == '__main__':
    main()
