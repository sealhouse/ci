#!/usr/bin/env python3
"""fake-github.py PORT LOG: the GitHub API calls ci's scripts make, for test-github.sh and test-report.sh."""
import base64, json, re, sys
from urllib.parse import parse_qs, urlsplit
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

    def reply(self, code, obj, link=None):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        if link:
            self.send_header("Link", link)
        self.end_headers()
        self.wfile.write(data)

    # page replies with one page of items, wrapped in key if given, and a Link to the next page.
    def page(self, items, key=None):
        size = state.get("page_size", 100)
        q = parse_qs(urlsplit(self.path).query)
        n = int(q.get("page", ["1"])[0])
        chunk = items[(n - 1) * size:n * size]
        link = None
        if n * size < len(items):
            q["page"] = [str(n + 1)]
            query = "&".join(f"{k}={v[0]}" for k, v in q.items())
            link = f'<http://127.0.0.1:{port}{urlsplit(self.path).path}?{query}>; rel="next", <http://127.0.0.1:{port}/last>; rel="last"'
        body = {key: chunk, "total_count": len(items)} if key else chunk
        return self.reply(200, body, link)

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
        q = parse_qs(urlsplit(path).query)
        for pattern in state.get("fail_paths", []):
            if re.search(pattern, path):
                return self.reply(502, {"message": "Server Error"})
        if p == "/orgs/sealhouse/installation":
            return self.reply(200, {"id": 7})
        if p == "/app/installations/7/access_tokens":
            return self.reply(201, {"token": "installation-token"})
        if p == "/graphql":
            if state.get("graphql_error"):
                return self.reply(200, {"data": None, "errors": [{"message": "auto-merge is off"}]})
            return self.reply(200, {"data": {}})
        m = re.match(r"/repos/([^/]+/[^/]+)(/.*)$", p)
        repo, rest = m.group(1).split("/")[1], m.group(2)
        wf = re.match(r"/actions/workflows/([^/]+)/runs$", rest)
        if method == "GET" and wf and q.get("created", [""])[0].startswith(">="):
            since, event = q["created"][0][2:], q.get("event", [None])[0]
            runs = [r for r in state.get("runs_by_repo", {}).get(repo, []) if r["path"].endswith("/" + wf.group(1))
                    and r["created_at"] >= since and event in (None, r["event"])]
            return self.page(runs, "workflow_runs")
        if method == "GET" and "pulls_by_repo" in state:
            if rest == "/pulls" and q.get("state") == ["all"]:
                return self.page(state["pulls_by_repo"].get(repo, []))
            rv = re.match(r"/pulls/(\d+)/reviews$", rest)
            if rv:
                return self.page(state.get("reviews", {}).get(f"{repo}#{rv.group(1)}", []))
            if rest == "/actions/runs":
                day = q.get("created", [""])[0]
                return self.page([r for r in state.get("runs_by_repo", {}).get(repo, []) if r["created_at"].startswith(day)], "workflow_runs")
            wf = re.match(r"/actions/workflows/([^/]+)/runs$", rest)
            if wf:
                runs = [r for r in state.get("runs_by_repo", {}).get(repo, []) if r["path"].endswith("/" + wf.group(1))
                        and r["head_sha"] == q.get("head_sha", [""])[0] and (q.get("status") != ["success"] or r["conclusion"] == "success")]
                return self.page(runs, "workflow_runs")
            jb = re.match(r"/actions/runs/(\d+)/jobs$", rest)
            if jb:
                return self.page(state.get("jobs", {}).get(jb.group(1), []), "jobs")
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
            return self.reply(200, {"behind_by": state.get("behind", {}).get(rest.split("...")[1], 0),
                                    "status": state.get("compare_status", {}).get(rest[len("/compare/"):], "ahead")})
        if method == "GET" and rest.endswith("/check-runs"):
            return self.reply(200, {"check_runs": state.get("checks_by_sha", {}).get(rest.split("/")[2], state["checks"])})
        if method == "POST" and rest.endswith("/requested_reviewers") and state.get("reviews_refused"):
            return self.reply(422, {"message": "Reviews may only be requested from collaborators."})
        if method == "GET" and re.match(r"/pulls/\d+$", rest):
            return self.reply(200, state.get("pr_details", {}).get(rest.split("/")[2], {}))
        pr = re.match(r"/pulls/(\d+)/(commits|files|merge)$", rest)
        if pr and method == "GET":
            return self.reply(200, state.get("pr_" + pr.group(2), {}).get(pr.group(1), []))
        if pr and method == "PUT":
            if pr.group(1) in state.get("merge_refused", []):
                return self.reply(405, {"message": "Required status check is expected."})
            return self.reply(200, {"merged": True})
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
