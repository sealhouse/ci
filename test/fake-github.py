#!/usr/bin/env python3
"""fake-github.py PORT LOG: the GitHub API calls ci's scripts make, for test-github.sh."""
import base64, json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, log = int(sys.argv[1]), sys.argv[2]
state = {"files": {}, "pulls": [], "checks": []}
seq = [0]


def sha():
    seq[0] += 1
    return f"{seq[0]:040x}"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def route(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        body = json.loads(raw) if raw else None
        path = self.path
        if path == "/__state":
            state.update(body)
            return self.reply(200, {})
        with open(log, "a") as f:
            auth = self.headers.get("Authorization", "")
            f.write(json.dumps({"method": method, "path": path, "auth": auth, "body": body}) + "\n")
        p = path.split("?")[0]
        if p == "/orgs/sealhouse/installation":
            return self.reply(200, {"id": 7})
        if p == "/app/installations/7/access_tokens":
            return self.reply(201, {"token": "installation-token"})
        if p == "/graphql":
            if state.get("graphql_error"):
                return self.reply(200, {"data": None, "errors": [{"message": "auto-merge is off"}]})
            return self.reply(200, {"data": {}})
        m = re.match(r"/repos/([^/]+/[^/]+)(/.*)$", p)
        rest = m.group(2)
        if method == "GET" and rest.startswith("/contents/"):
            name = rest[len("/contents/"):]
            if name == "versions":
                return self.reply(200, [{"type": "dir", "name": "2.0"}, {"type": "file", "name": "embed.go"}])
            listed = [f[len(name) + 1:] for f in state["files"] if f.startswith(name + "/")]
            if listed:
                return self.reply(200, [{"type": "file", "name": f} for f in listed])
            if name not in state["files"]:
                return self.reply(404, {})
            content = base64.b64encode(state["files"][name].encode()).decode()
            return self.reply(200, {"content": content})
        if method == "GET" and rest.startswith("/git/ref/"):
            if rest[len("/git/ref/"):] in state.get("missing_refs", []):
                return self.reply(404, {})
            return self.reply(200, {"object": {"sha": "a" * 40}})
        if method == "GET" and rest.startswith("/git/commits/"):
            return self.reply(200, {"tree": {"sha": "b" * 40}})
        if method == "POST" and rest in ("/git/blobs", "/git/trees", "/git/commits", "/git/refs"):
            return self.reply(201, {"sha": sha()})
        if method == "GET" and rest == "/pulls":
            return self.reply(200, state["pulls"])
        if method == "POST" and rest == "/pulls":
            pr = {"number": len(state["pulls"]) + 100, "node_id": "PR_new", "base": {"ref": body["base"]}, "head": {"ref": body["head"], "sha": "c" * 40}}
            state["pulls"].append(pr)
            return self.reply(201, pr)
        if method == "GET" and rest.startswith("/compare/"):
            return self.reply(200, {"behind_by": state.get("behind", {}).get(rest.split("...")[1], 0)})
        if method == "GET" and rest.endswith("/check-runs"):
            return self.reply(200, {"check_runs": state.get("checks_by_sha", {}).get(rest.split("/")[2], state["checks"])})
        if method == "POST" and rest.endswith("/requested_reviewers") and state.get("reviews_refused"):
            return self.reply(422, {"message": "Reviews may only be requested from collaborators."})
        if method == "GET" and rest == "/actions/workflows":
            return self.reply(200, {"workflows": state.get("workflows", [])})
        return self.reply(200, {})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_DELETE(self):
        self.route("DELETE")

    def do_PUT(self):
        self.route("PUT")


HTTPServer(("127.0.0.1", port), H).serve_forever()
