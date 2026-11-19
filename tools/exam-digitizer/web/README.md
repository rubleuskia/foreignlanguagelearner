# Exam web interface

Keep this interface as the starting point for the application's future web client.
The source lives in Git; examination JSON, answer keys, PDFs, audio, generated
snapshots and attempts belong in the external `ExamSources` archive.

Current `index.html` / `app.mjs` is the **local authoring and review interface**.
It renders the original task layouts, training audio controls, uninterrupted exam
audio, local resume, timers, objective results and explicit AI placeholders. It
loads the full authoring package, including keys, and must never be served as a
public student application. `exam_digitizer.py serve` remains its local entry point.

`backend-client.mjs` is the separately testable transport for the future authenticated
web application. It calls the same `/v1/exams` and `/v1/exam-attempts` routes as iOS,
takes short-lived credentials from its host, keeps no token in localStorage, and
does not silently retry mutations. The server controls grades, versions and deadlines.

Before enabling a hosted student mode: connect the existing renderer to the
answer-key-free student projection; replace local grading with server results;
add account-scoped IndexedDB drafts/outbox, explicit version-conflict recovery,
Cognito sign-in and signed media downloads; wire the existing text-translation AI
route for submitted free-text tasks. Keep authoring and student entry points distinct.
The current review application does not claim to implement those hosted features.
