# Cobble_Project — Discussion Thread PoC

A Week 13 proof of concept: a discussion-thread plugin that runs end to end across three Docker containers (UI → API → SQL Server).

## Architecture

| Container | Tech | What it does | URL on your machine |
|---|---|---|---|
| `cobble_ui` | Node 20 + Express, React (in-browser) | Shows the thread; lets you add, edit, delete, vote on and report comments | http://localhost:8080 |
| `cobble_api` | Python 3.11, FastAPI, Swagger UI | Business logic; calls stored procedures only (never touches tables directly) | http://localhost:8081/docs |
| `cobble_sql` | Microsoft SQL Server 2022 (Developer) | Schema `dsc`, stored procedures, seed data in database `DiscussionPoC` | `localhost,1433` |
| `cobble_sql_init` | sqlcmd (runs once, then exits) | Applies `sql/init/init.sql` to create the database, procedures and seed data | — |

Core requirements covered:
1. Fetching and displaying a single thread of comments from the SQL database.
2. Adding and removing comments through the UI.

Extras: editing your own comment, one-level replies, like/dislike voting with a karma leaderboard, and reporting comments for moderation. A "viewing as" picker in the UI switches between three seeded members (Jane, Sam, Alex) so you can test the author-only rules.

<img width="897" height="649" alt="Screenshot of the discussion thread UI" src="https://github.com/user-attachments/assets/f9336ee0-a6ef-4037-9b38-bf86a68c4bfb" />

---

## 1. What you need

The only thing to install is **Docker Desktop**. Python, Node and SQL Server all run inside the containers.

| | Windows 10/11 | macOS |
|---|---|---|
| Install | [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/) — accept the **WSL 2** option when asked, then restart | [Docker Desktop for Mac](https://docs.docker.com/desktop/setup/install/mac-install/) — pick the **Apple silicon** or **Intel** download to match your Mac |
| Extra setting | None | **Apple silicon (M1–M4) only:** Docker Desktop → Settings → General → turn on **"Use Rosetta for x86_64/amd64 emulation on Apple Silicon"**, then Apply & Restart. SQL Server only ships as an Intel image. |
| Memory | SQL Server needs at least **2 GB** of RAM available to Docker | same |

Docker Desktop must be **open and running** (whale icon in the taskbar / menu bar) before you run any commands.

The browser also needs an internet connection the first time, because the UI loads React from a CDN (unpkg.com).

Check it works — open a terminal (**PowerShell** on Windows, **Terminal** on Mac) and run:

```
docker --version
docker compose version
```

Both should print a version number.

---

## 2. Unzip and open a terminal in the project folder

Unzip `Cobble_Project.zip`, then open a terminal **inside** the `Cobble_Project` folder (the one containing `docker-compose.yml`).

**Windows:** open the folder in File Explorer, click the address bar, type `powershell` and press Enter.
Or in PowerShell:
```powershell
cd "$HOME\Downloads\Cobble_Project"
```

**macOS:** in Finder, right-click the folder → **New Terminal at Folder** (or drag the folder onto the Terminal icon).
Or in Terminal:
```bash
cd ~/Downloads/Cobble_Project
```

(Adjust the path if you unzipped it somewhere else.)

---

## 3. Create the `.env` file (database password)

The project reads the SQL Server admin password from a file called `.env` next to `docker-compose.yml`. A template, `.env.example`, is included.

> If a `.env` file is already in the folder, you can skip this step.

**Windows (PowerShell):**
```powershell
Copy-Item .env.example .env
notepad .env
```

**macOS (Terminal):**
```bash
cp .env.example .env
open -e .env
```

Set the password on the one line in the file and save it, for example:

```
SA_PASSWORD=CobbleDemo2026!
```

SQL Server will **refuse to start** unless the password:
- is at least 8 characters, and
- contains at least three of: uppercase, lowercase, digits, symbols.

Also avoid `$`, quotes and spaces in the password, because Docker Compose treats them specially.

> Windows note: files starting with a dot are hidden in File Explorer by default. Turn on **View → Show → Hidden items** if you want to see `.env` there.

---

## 4. Build and start everything

From the project folder (same command on Windows and Mac):

```
docker compose up --build
```

The first run takes a few minutes, because it downloads the SQL Server image (~1.5 GB) and builds the API and UI images. The containers start in order:

1. `sql` starts and waits until it is healthy (can take up to a minute; longer on Apple silicon under emulation),
2. `sql-init` creates the database, procedures and seed data, then **exits** — that is expected,
3. `api` starts once the database is ready,
4. `ui` starts once the API reports healthy.

It is ready when the log shows a line like:

```
cobble_ui  | discussion-thread ui listening on :8080, API_BASE_URL=http://localhost:8081
```

Leave this terminal open; it shows the live logs. (To run in the background instead, use `docker compose up --build -d`.)

---

## 5. Use it

| What | Open |
|---|---|
| The app (discussion thread) | http://localhost:8080 |
| API docs / try requests (Swagger UI) | http://localhost:8081/docs |
| API health check | http://localhost:8081/health → `{"status":"healthy"}` |

Things to try in the UI:
- Add a comment, and reply to one.
- Edit or delete one of **your** comments (only the author can; try switching "viewing as" to another member and you will see this is refused).
- Like/dislike someone else's comment and watch the karma leaderboard update (you cannot vote on your own).
- Report a comment.

### Optional: Postman

A Postman collection is in `postman/DiscussionThreadPoC.postman_collection.json`. Import it and the requests are ready to run: its `baseUrl` variable is already set to `http://localhost:8081` (the API port). The seeded thread id is `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`.

### Optional: look at the database directly

Connect with Azure Data Studio, SSMS (Windows) or VS Code's SQL Server extension:

- Server: `localhost,1433`
- Login: `sa`
- Password: the value from `.env`
- Database: `DiscussionPoC`
- Tick **Trust server certificate**

---

## 6. Stop, restart and reset

| Action | Command |
|---|---|
| Stop (if running in the foreground) | `Ctrl + C` in the terminal |
| Stop and remove the containers (data is kept) | `docker compose down` |
| Start again later | `docker compose up` |
| Full reset — wipe the database and start fresh | `docker compose down -v` then `docker compose up --build` |

`init.sql` is idempotent, so restarting never duplicates the seed data.

---

## 7. Troubleshooting

**"Cannot connect to the Docker daemon" / "docker: command not found"**
Docker Desktop isn't running. Open it, wait until it says *Engine running*, then try again. On Windows, open a new PowerShell window after installing.

**`cobble_sql` keeps restarting or is "unhealthy"**
Almost always the password. Check the logs:
```
docker compose logs sql
```
If you see a password-policy error, make the password in `.env` stronger, then run `docker compose down -v` and `docker compose up --build`. (The `-v` matters: SQL Server keeps the first password it was started with.)

**"dependency failed to start: container cobble_sql is unhealthy" (often on Apple silicon, first run)**
SQL Server took longer to start than Docker was willing to wait — common on the very first run, and under Rosetta emulation. Nothing is broken: run `docker compose up` again and it will pick up where it left off. If it happens every time, give Docker Desktop more memory (Settings → Resources).

**Mac with Apple silicon: SQL Server crashes or won't start**
Make sure the Rosetta setting from step 1 is on, and that Docker Desktop is up to date.

**"port is already allocated" (1433, 8080 or 8081)**
Something else on your computer is using that port — on Windows, often a locally installed SQL Server (stop the *SQL Server (MSSQLSERVER)* service in `services.msc`), or another web app on 8080. Stop it, or change the left-hand number in the `ports:` line of `docker-compose.yml` (e.g. `"14330:1433"`). If you change the API's port `8081`, also update `API_BASE_URL` under the `ui` service to match.

**The page loads but shows no comments / errors**
- Open http://localhost:8081/health — if it doesn't respond, the API isn't up yet; check `docker compose logs api`.
- Check that `sql-init` finished successfully: `docker compose ps -a` should show `cobble_sql_init` as *Exited (0)*. If it's not 0, see `docker compose logs sql-init`.
- Make sure the browser has internet access (React is loaded from unpkg.com).

**Something odd after editing files**
Rebuild: `docker compose up --build`.

---

## Sharing the project as a zip

Don't zip your project folder directly: it would include your `.env` (with your real database password) and hidden system files such as `.DS_Store`. Instead, from the project folder, let git build the zip from committed files only:

```
git archive --format=zip --prefix=Cobble_Project/ -o ../Cobble_Project.zip HEAD
```

This writes `Cobble_Project.zip` next to the project folder. It contains `.env.example` but never `.env`, so the person receiving it follows step 3 to set their own password. (Commit any changes first — uncommitted edits are not included.)

---

## Project layout

```
Cobble_Project/
├── docker-compose.yml        # wires the 4 services together
├── .env.example              # copy to .env and set SA_PASSWORD
├── api/                      # FastAPI backend
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
│       ├── main.py           # routes (Swagger at /docs)
│       ├── db.py             # calls stored procedures only
│       ├── identity.py       # dev-only tenant/member identity
│       └── models.py         # request/response models
├── ui/                       # Express static server + React page
│   ├── server.js
│   └── src/index.html
├── sql/
│   ├── init/init.sql         # ← the script that actually runs at startup
│   ├── init/0xx–1xx-*.sql    # fuller Cobble398 schema, not wired in yet
│   └── tests/                # SQL isolation/negative tests
└── postman/                  # Postman collection
```

> Note: only `sql/init/init.sql` is executed by `docker compose`. The numbered scripts in `sql/init/` and `sql/Dockerfile` belong to the fuller membership schema (database `Cobble398`, see `sql/README-discussion.md`) and are not used by this PoC run.
