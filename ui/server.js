import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT      = process.env.PORT || 8080;
const API_BASE  = process.env.API_BASE_URL || "http://api:8080";

const app = express();

// Server-side proxy. The browser calls same-origin /api/health; this process
// forwards to the API by its Docker service name. No CORS, and no localhost
// between containers (§3).
app.get("/api/health", async (_req, res) => {
  try {
    const upstream = await fetch(`${API_BASE}/health`);
    const body     = await upstream.text();
    res.status(upstream.status).type("application/json").send(body);
  } catch (err) {
    res.status(502).json({ status: "unreachable", error: String(err) });
  }
});

app.use(express.static(path.join(__dirname, "dist")));

app.listen(PORT, () =>
  console.log(`Cobble UI listening on ${PORT}, upstream ${API_BASE}`)
);
