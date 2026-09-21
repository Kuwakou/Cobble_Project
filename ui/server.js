// Thin UI static server. Serves pre-built static files and a tiny
// generated config.js so the browser knows where the API lives — this
// process itself never talks to SQL, only the browser -> API.
const express = require("express");
const path = require("path");

const app = express();
const PORT = process.env.PORT || 3000;
// Browser-reachable API base. Container-to-container calls use the
// service name "api", but the browser runs on the host, so it needs the
// host-published port.
const API_BASE_URL = process.env.API_BASE_URL || "http://localhost:8080";

app.get("/config.js", (_req, res) => {
  res.type("application/javascript");
  res.send(`window.API_BASE_URL = ${JSON.stringify(API_BASE_URL)};`);
});

app.use(express.static(path.join(__dirname, "src")));

app.listen(PORT, () => {
  console.log(`discussion-thread ui listening on :${PORT}, API_BASE_URL=${API_BASE_URL}`);
});
