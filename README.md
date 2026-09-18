# Cobble_Project

##Architecture Breakdown
- Frontend (Docker container 1): Built with React/HTML. It presents the user interface and communicates back and forth with the backend API
- Backend (Docker container 2): Powered by Python and includes Swagger UI for API documentation and testing. It handles business logic and communicates between the UI and database.
- Database (Docker container 3): Structured using a SQL schema. The Python backend reads and writes data to and from these database tables.

##Scope & Deliverables
- Deliverable Goal: Week 13 Proof of Concept for the Cobble_Project
- Core Requirements: Built a plugin that cycles through the architecture to handle:
  1. Fetching and displaying a single thread of comments from the SQL database.
  2. Allowing users to add and remove comments via the UI.
 

<img width="897" height="649" alt="Screenshot 2026-09-18 at 7 37 17 pm" src="https://github.com/user-attachments/assets/f9336ee0-a6ef-4037-9b38-bf86a68c4bfb" />
