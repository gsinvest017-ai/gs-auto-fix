"""打版流水線自我測試用的最小服務。

刻意只用標準庫、只有一個健康端點：這支存在的目的是驗證**流水線**，不是驗證
任何應用邏輯。任何額外相依都只會讓「流水線壞了」與「這支服務壞了」混在一起。
"""
import http.server
import os
import socketserver

VERSION = os.environ.get("SELFTEST_VERSION", "dev")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = f"ok {VERSION}".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *_):
        pass  # 健康探測每 2 秒打一次，不要洗版 docker logs


if __name__ == "__main__":
    with socketserver.TCPServer(("0.0.0.0", 8099), Handler) as httpd:
        print(f"selftest {VERSION} listening on 8099", flush=True)
        httpd.serve_forever()
