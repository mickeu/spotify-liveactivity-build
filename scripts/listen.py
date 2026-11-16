import socket, sys, time
out = '/var/minis/workspace/liveisland/logs/live.log'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 18888))
with open(out, 'ab', buffering=0) as f:
    while True:
        try:
            data, _ = s.recvfrom(8192)
            f.write(data)
        except Exception:
            time.sleep(0.2)
