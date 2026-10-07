"""CI 用的本地行情：先让主备均返回 503，出现 recover 文件后主源恢复。"""
import datetime
import http.server
import json
import pathlib
import sys
import socketserver
import time

root = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        recovered = (root / "recover").exists() and self.path.startswith("/primary")
        status = 200 if recovered else 503
        with (root / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"time": time.monotonic(), "path": self.path, "status": status}) + "\n")
        fields = [""] * 40
        fields[0:7] = ["1", "Recovery fixture", "600519", "100.00", "99.00", "99.00", "10"]
        fields[30] = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime("%Y%m%d%H%M%S")
        fields[31:35] = ["1.00", "1.01", "101.00", "98.00"]
        body = ('v_sh600519="' + "~".join(fields) + '";').encode() if recovered else b"Temporarily unavailable"
        self.send_response(status)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


# HTTPServer 会反查主机名，macOS CI 可能停在“本地网络”授权；只绑定回环 TCP。
class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_address[1]))
server.serve_forever()
