// Guard proxy in front of Cap's Next.js server.
//
// Listens on the Cloudron httpPort (3000) and forwards to Next on 127.0.0.1:3001. Internal callers
// (the workflow queue, media-server webhooks) talk to 127.0.0.1:3001 directly and never pass here.
//
// It closes paths that external clients must not reach on a shared Cloudron server:
//   * user-supplied S3 endpoints ("custom storage"): the server would connect to any host the user
//     enters and return the response, i.e. a scanner/reader for the internal Docker network.
//     Blocked: /api/desktop/s3/* writes and the organisation storage server actions.
//   * internal endpoints: /api/cron/*, /api/dev-reset-transcript, /.well-known/workflow/v1/{flow,step}
// and rate-limits anonymous endpoints that are expensive to serve (OG image rendering, the image
// optimizer, the Loom downloader, the docs AI).
//
// Set CAP_ALLOW_CUSTOM_STORAGE=true in env.sh to re-enable custom S3 storage.

import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";

const LISTEN_PORT = 3000;
const UPSTREAM = { host: "127.0.0.1", port: 3001 };
const MANIFEST = "/app/code/web/apps/web/.next/server/server-reference-manifest.json";
const ALLOW_CUSTOM_STORAGE = process.env.CAP_ALLOW_CUSTOM_STORAGE === "true";
const MAX_FORM_BODY = 20 * 1024 * 1024;

const log = (msg) => console.log(`[guard-proxy] ${msg}`);

// --- blocked server actions -------------------------------------------------------------------

// Server action ids change with every Cap build, so they are looked up by source file and name.
function blockedActionIds() {
  if (ALLOW_CUSTOM_STORAGE) return new Set();
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
  } catch (err) {
    log(`ERROR: cannot read ${MANIFEST}: ${err.message}`);
    return null;
  }
  const ids = new Set();
  for (const [id, entry] of Object.entries(manifest.node ?? {})) {
    const file = entry.filename ?? "";
    const name = entry.exportedName ?? "";
    if (file.endsWith("actions/organization/storage.ts") && /S3|StorageProvider/.test(name)) {
      ids.add(id);
    }
  }
  return ids;
}

const BLOCKED_ACTIONS = blockedActionIds();
if (BLOCKED_ACTIONS === null || (!ALLOW_CUSTOM_STORAGE && BLOCKED_ACTIONS.size === 0)) {
  // Fail closed: without the ids we cannot tell the storage actions apart from the others.
  log("ERROR: storage server actions not found in the manifest; refusing to start");
  process.exit(1);
}
log(ALLOW_CUSTOM_STORAGE ? "custom S3 storage allowed (CAP_ALLOW_CUSTOM_STORAGE=true)"
                         : `blocking ${BLOCKED_ACTIONS.size} storage server actions`);
if (process.argv.includes("--check")) process.exit(0); // build-time self test

// --- path rules -------------------------------------------------------------------------------

// Canonical form for matching: decoded, dot-segments resolved, no duplicate or trailing slashes,
// lower case. Matching is deliberately broader than Next's own (case-sensitive) routing.
function canonicalPath(rawUrl) {
  let p = (rawUrl ?? "/").split("?")[0];
  for (let i = 0; i < 3; i++) {
    try {
      const decoded = decodeURIComponent(p);
      if (decoded === p) break;
      p = decoded;
    } catch {
      return null;
    }
  }
  p = path.posix.normalize("/" + p.replace(/\\/g, "/")).replace(/\/+/g, "/");
  if (p.length > 1) p = p.replace(/\/$/, "");
  return p.toLowerCase();
}

function isBlockedPath(p, method) {
  if (p.startsWith("/api/cron/") || p === "/api/cron") return true;
  if (p.startsWith("/api/dev-reset-transcript")) return true;
  if (p === "/.well-known/workflow/v1/flow" || p === "/.well-known/workflow/v1/step") return true;
  if (!ALLOW_CUSTOM_STORAGE && p.startsWith("/api/desktop/s3") && method !== "GET" && method !== "HEAD") {
    return true;
  }
  return false;
}

// --- rate limiting ----------------------------------------------------------------------------

const LIMITS = [
  { match: (p) => p === "/api/og" || p === "/api/video/og", perMinute: 30 },
  { match: (p) => p === "/_next/image", perMinute: 2000 }, // offices share one IP; thumbnails
  { match: (p) => p.startsWith("/api/tools/loom-download"), perMinute: 10 },
  { match: (p) => p === "/api/docs/ask", perMinute: 10 },
];
const buckets = new Map();

function clientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded) return forwarded.split(",")[0].trim();
  return req.socket.remoteAddress ?? "unknown";
}

function rateLimited(p, ip) {
  const rule = LIMITS.find((r) => r.match(p));
  if (!rule) return false;
  const key = `${LIMITS.indexOf(rule)}|${ip}`;
  const now = Date.now();
  const bucket = buckets.get(key) ?? { tokens: rule.perMinute, at: now };
  bucket.tokens = Math.min(rule.perMinute, bucket.tokens + ((now - bucket.at) / 60000) * rule.perMinute);
  bucket.at = now;
  buckets.set(key, bucket);
  if (bucket.tokens < 1) return true;
  bucket.tokens -= 1;
  return false;
}

setInterval(() => {
  const cutoff = Date.now() - 10 * 60000;
  for (const [key, bucket] of buckets) if (bucket.at < cutoff) buckets.delete(key);
}, 60000).unref();

// --- proxying ---------------------------------------------------------------------------------

const agent = new http.Agent({ keepAlive: true, maxSockets: 256 });

function deny(res, status, reason) {
  res.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end(`${reason}\n`);
}

function forward(req, res, body) {
  const upstream = http.request(
    { ...UPSTREAM, agent, method: req.method, path: req.url, headers: req.headers },
    (upRes) => {
      res.writeHead(upRes.statusCode ?? 502, upRes.statusMessage, upRes.rawHeaders);
      upRes.pipe(res);
    },
  );
  upstream.on("error", (err) => {
    if (!res.headersSent) deny(res, 502, "Bad gateway");
    else res.destroy(err);
  });
  // Client went away before the response finished: drop the upstream request too.
  res.on("close", () => {
    if (!res.writableFinished) upstream.destroy();
  });
  if (body) upstream.end(body);
  else req.pipe(upstream);
}

// A server action can also arrive without the Next-Action header, as a no-JS form post. Next.js
// reads the action id either from a "$ACTION_ID_<id>" field name or from the JSON value of a
// "$ACTION_<n>:<k>" field ({"id": "<id>", ...}, referenced by "$ACTION_REF_<n>"). Parse the form
// and collect every action id; refuse forms that mention actions but can't be parsed.
function formFields(body, contentType) {
  if (contentType.startsWith("application/x-www-form-urlencoded")) {
    return [...new URLSearchParams(body.toString("utf8")).entries()];
  }
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType);
  if (!match) return null;
  const boundary = `--${match[1] ?? match[2].trim()}`;
  const fields = [];
  for (const part of body.toString("latin1").split(boundary).slice(1)) {
    if (part.startsWith("--")) break;
    const split = part.indexOf("\r\n\r\n");
    if (split === -1) continue;
    const headers = part.slice(0, split);
    const name = /content-disposition:[^\r\n]*;\s*name="([^"]*)"/i.exec(headers)?.[1];
    if (name === undefined) return null; // e.g. RFC 2231 name*= encoding: can't verify
    const value = Buffer.from(part.slice(split + 4).replace(/\r\n$/, ""), "latin1").toString("utf8");
    fields.push([Buffer.from(name, "latin1").toString("utf8"), value]);
  }
  return fields;
}

function formActionIds(fields) {
  const ids = [];
  for (const [name, value] of fields) {
    if (name.startsWith("$ACTION_ID_")) ids.push(name.slice("$ACTION_ID_".length));
    else if (/^\$ACTION_\d+:\d+$/.test(name)) {
      try {
        const id = JSON.parse(value)?.id;
        if (typeof id === "string") ids.push(id);
      } catch {
        ids.push(null); // unparsable action reference
      }
    }
  }
  return ids;
}

function formCarriesBlockedAction(body, contentType) {
  const raw = body.toString("latin1");
  for (const id of BLOCKED_ACTIONS) if (raw.includes(id)) return true;
  if (!/\$ACTION_|%24ACTION_/i.test(raw)) return false; // not a server action submission
  const fields = formFields(body, contentType);
  if (fields === null) return true;
  const ids = formActionIds(fields);
  if (ids.length === 0 || ids.includes(null)) return true; // mentions actions we couldn't identify
  return ids.some((id) => BLOCKED_ACTIONS.has(id.trim()));
}

const server = http.createServer((req, res) => {
  const p = canonicalPath(req.url);
  if (p === null) return deny(res, 400, "Bad request");

  if (isBlockedPath(p, req.method)) {
    log(`blocked ${req.method} ${p} from ${clientIp(req)}`);
    return deny(res, 403, "Forbidden");
  }
  if (rateLimited(p, clientIp(req))) return deny(res, 429, "Too many requests");

  const action = req.headers["next-action"];
  if (typeof action === "string" && BLOCKED_ACTIONS.has(action.trim())) {
    log(`blocked server action ${action.trim()} from ${clientIp(req)}`);
    return deny(res, 403, "Forbidden");
  }

  const type = String(req.headers["content-type"] ?? "");
  // Inspect form posts on every path: Next's routing is case-sensitive, so e.g. /API/x is not an
  // API route but a page (its not-found page), where server actions are decoded.
  const formPost = req.method === "POST" && !action &&
    (type.startsWith("multipart/form-data") || type.startsWith("application/x-www-form-urlencoded"));
  if (!formPost || BLOCKED_ACTIONS.size === 0) return forward(req, res);

  const chunks = [];
  let size = 0;
  req.on("data", (chunk) => {
    size += chunk.length;
    if (size > MAX_FORM_BODY) {
      if (!res.headersSent) {
        res.on("finish", () => req.destroy()); // drop the rest of the upload once 413 is out
        deny(res, 413, "Payload too large");
      }
      return;
    }
    chunks.push(chunk);
  });
  req.on("end", () => {
    if (res.headersSent) return;
    const body = Buffer.concat(chunks);
    if (formCarriesBlockedAction(body, type)) {
      log(`blocked form server action from ${clientIp(req)}`);
      return deny(res, 403, "Forbidden");
    }
    forward(req, res, body);
  });
});

// WebSocket and other upgrades: same path rules, then a raw TCP pipe to Next.
server.on("upgrade", (req, socket, head) => {
  const p = canonicalPath(req.url);
  if (p === null || isBlockedPath(p, req.method)) {
    socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
    return;
  }
  const upstream = net.connect(UPSTREAM.port, UPSTREAM.host, () => {
    let head0 = `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n`;
    for (let i = 0; i < req.rawHeaders.length; i += 2) head0 += `${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`;
    upstream.write(head0 + "\r\n");
    if (head?.length) upstream.write(head);
    socket.pipe(upstream).pipe(socket);
  });
  upstream.on("error", () => socket.destroy());
  socket.on("error", () => upstream.destroy());
});

server.requestTimeout = 0; // long streams and uploads
server.headersTimeout = 60000;
server.keepAliveTimeout = 75000; // longer than the platform's nginx keepalive
server.listen(LISTEN_PORT, "0.0.0.0", () => log(`listening on :${LISTEN_PORT} -> ${UPSTREAM.host}:${UPSTREAM.port}`));

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
