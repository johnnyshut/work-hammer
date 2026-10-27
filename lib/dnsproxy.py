import socket
import struct
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPSTREAM = None


def read_env(path):
    vals = {}
    if not path.exists():
        return vals
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            vals[key.strip()] = value.strip()
    return vals


def zones():
    found = []
    for name in ("forti", "l2tp", "cisco"):
        env = read_env(ROOT / name / ".env")
        dns_file = ROOT / name / "state" / "dns"
        dns = ""
        if dns_file.exists():
            lines = [x.strip() for x in dns_file.read_text(encoding="utf-8", errors="replace").splitlines() if x.strip()]
            dns = lines[0] if lines else ""
        if not dns:
            continue
        kind = "socks" if name == "cisco" else "wsl"
        for domain in env.get("DOMAINS", "").replace(",", " ").split():
            domain = domain.strip().lstrip(".")
            if domain:
                found.append((domain, kind, dns))
    found.sort(key=lambda item: len(item[0]), reverse=True)
    return found


def qname(msg):
    parts = []
    i = 12
    while i < len(msg):
        size = msg[i]
        if size == 0 or size & 0xC0:
            break
        i += 1
        parts.append(msg[i:i + size].decode("ascii", "replace"))
        i += size
    return ".".join(parts)


def recvall(con, size):
    data = b""
    while len(data) < size:
        chunk = con.recv(size - len(data))
        if not chunk:
            break
        data += chunk
    return data


def tcp_query(con, msg):
    con.sendall(struct.pack(">H", len(msg)) + msg)
    hdr = recvall(con, 2)
    if len(hdr) < 2:
        return b""
    return recvall(con, struct.unpack(">H", hdr)[0])


def via_wsl(msg):
    con = socket.create_connection(UPSTREAM, 3)
    try:
        con.settimeout(3)
        return tcp_query(con, msg)
    finally:
        con.close()


def via_socks(msg, dns_ip):
    con = socket.create_connection(("127.0.0.1", 1080), 3)
    try:
        con.settimeout(3)
        con.sendall(b"\x05\x01\x00")
        if recvall(con, 2) != b"\x05\x00":
            return b""
        ip = socket.inet_aton(dns_ip)
        con.sendall(b"\x05\x01\x00\x01" + ip + struct.pack(">H", 53))
        head = recvall(con, 4)
        if len(head) < 4 or head[1] != 0:
            return b""
        atyp = head[3]
        if atyp == 1:
            recvall(con, 6)
        elif atyp == 4:
            recvall(con, 18)
        elif atyp == 3:
            ln = recvall(con, 1)
            recvall(con, ln[0] + 2)
        return tcp_query(con, msg)
    finally:
        con.close()


def forward(msg):
    name = qname(msg).lower()
    for domain, kind, dns in zones():
        if name == domain or name.endswith("." + domain):
            if kind == "socks":
                return via_socks(msg, dns)
            return via_wsl(msg)
    return via_wsl(msg)


def reply(sock, msg, addr):
    try:
        ans = forward(msg)
        if ans:
            sock.sendto(ans, addr)
    except OSError:
        return


def main():
    global UPSTREAM
    UPSTREAM = (sys.argv[1], int(sys.argv[2]))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 53))
    while True:
        try:
            msg, addr = sock.recvfrom(4096)
        except ConnectionResetError:
            continue
        threading.Thread(target=reply, args=(sock, msg, addr), daemon=True).start()


if __name__ == "__main__":
    main()
