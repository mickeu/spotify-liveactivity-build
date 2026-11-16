import socket, threading
OUT='/var/minis/workspace/liveisland/logs/live.log'
srv=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1',18890)); srv.listen(32)
def handle(c):
    with c:
        try:
            data=c.recv(8192)
            if data:
                with open(OUT,'ab',buffering=0) as f: f.write(data)
        except Exception: pass
while True:
    try:
        c,_=srv.accept()
        threading.Thread(target=handle,args=(c,),daemon=True).start()
    except Exception: pass
