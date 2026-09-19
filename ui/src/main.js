const statusEl = document.querySelector("#status");
const detailEl = document.querySelector("#detail");
const buttonEl = document.querySelector("#refresh");

async function checkApi() {
  statusEl.textContent = "checking…";
  statusEl.className = "pill pill--pending";

  try {
    const res  = await fetch("/api/health");
    const data = await res.json();
    const ok   = res.ok && data.status === "healthy";

    statusEl.textContent = ok ? "API healthy" : `API returned ${res.status}`;
    statusEl.className   = `pill ${ok ? "pill--ok" : "pill--fail"}`;
    detailEl.textContent = JSON.stringify(data, null, 2);
  } catch (err) {
    statusEl.textContent = "API unreachable";
    statusEl.className   = "pill pill--fail";
    detailEl.textContent = String(err);
  }
}

buttonEl.addEventListener("click", checkApi);
checkApi();
