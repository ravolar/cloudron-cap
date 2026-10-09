// Upstream's entry exports { port, fetch } and lets Bun serve it on all interfaces, which would
// expose the media server to every container on the Cloudron network. Re-export it bound to
// loopback only; cap-web is the sole client. Importing the module also keeps upstream's
// SIGTERM/SIGINT handlers (abort jobs, clean the transfer cache).
import server from "/app/code/media/src/index.ts";

export default { ...server, hostname: "127.0.0.1" };
