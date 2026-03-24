# OpenClaw Teams Plugin — Manual Test Plan

Reusable manual test plan for the Microsoft Teams extension. Run these tests after any significant changes to `extensions/msteams/`.

## Prerequisites

- OpenClaw deployed with msteams plugin enabled (VM or dev tunnel)
- Azure Bot registered with Teams channel enabled
- Teams app package sideloaded
- Bot added to at least one Team (for channel tests)
- DM pairing approved for the test user

## Test Execution

For each test, record: PASS / FAIL / BLOCKED, with observations.

---

## A. 1:1 Personal Chat

### A1. Basic Reply
- **Steps:** Send "Hello" in 1:1 chat with the bot
- **Expected:** Bot replies with a text response within 10s
- **Verify:** Response appears in the chat

### A2. AI Label
- **Steps:** Check any bot response
- **Expected:** "AI generated" badge appears next to the bot name on the response
- **Verify:** Badge is visible in the message header

### A3. AI Disclaimer
- **Steps:** Check any bot response message group
- **Expected:** "AI-generated content may be incorrect" text shown in the message group aria label
- **Verify:** Visible on hover or in accessibility tree

### A4. Streaming (Progressive Updates)
- **Steps:** Ask the bot to "Write a detailed 3-paragraph explanation of [topic]"
- **Expected:** Text appears progressively (word by word / chunk by chunk), not all at once. Typing dots (●●●) visible during generation. A "Stop" button may appear.
- **Verify:** Take a mid-stream screenshot showing partial text

### A5. Long Response Completes
- **Steps:** Same as A4 — wait for response to finish
- **Expected:** Full response renders with formatting (bold, paragraphs). No truncation or error.
- **Verify:** Response has multiple paragraphs with proper markdown rendering

### A6. Thumbs Up (Like) Feedback
- **Steps:** Click the thumbs up icon on any bot response
- **Expected:** Feedback dialog opens with "What did you like?" prompt
- **Verify:** Dialog title says "Submit feedback to [bot name]"

### A7. Thumbs Down (Dislike) Feedback
- **Steps:** Click the thumbs down icon on any bot response
- **Expected:** Feedback dialog opens with "What went wrong?" prompt
- **Verify:** Dialog title matches; different question than thumbs up

### A8. Feedback Submission
- **Steps:** Type feedback text in the dialog and click Submit
- **Expected:** "Feedback submitted." toast notification appears. Like/Dislike button shows active state.
- **Server check:** `grep "received feedback" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log` shows entry

### A9. Feedback Reflection (Dislike)
- **Steps:** Submit negative (dislike) feedback
- **Server check:** Look for reflection-related log entries. The bot may send a follow-up message based on the reflection.
- **Note:** Reflection has a 5-minute cooldown per session

### A10. Welcome Card on Install
- **Steps:** Remove and re-add the bot, or check the first message in the conversation
- **Expected:** Adaptive Card with bot greeting and prompt starters (default: "What can you do?", "Summarize my last meeting", "Help me draft an email")
- **Verify:** Card renders with clickable buttons

### A11. Prompt Starters (Welcome Card Buttons)
- **Steps:** Click one of the prompt starter buttons on the welcome card
- **Expected:** The button text is sent as a message to the bot, which replies normally

### A12. View Prompts Button
- **Steps:** Click "View prompts" at the bottom of the chat
- **Expected:** Popup shows "Prompt Suggestions from [bot name]" with available commands (e.g. "Help")

### A13. Typing Indicator in 1:1
- **Steps:** Send a message and watch for typing indicator before response
- **Expected:** Typing dots appear while bot is processing/streaming

### A14. Image Attachment (Requires Graph Permissions)
- **Steps:** Paste or attach an image in the chat with a question about it
- **Expected (with Graph perms):** Bot receives and describes the image
- **Expected (without Graph perms):** Bot replies but says it can't see the image. Server logs show `"inline images detected but none downloaded"` and `"graph media fetch empty"`
- **Server check:** `grep "inline images\|graph media" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`

### A15. Rapid Messages (Duplicate Prevention)
- **Steps:** Send 2 messages within 1 second
- **Expected:** Bot replies to BOTH messages separately, no duplicates, no crashes
- **Verify:** Each message gets exactly one response

---

## B. Channel Tests

### B1. @Mention in Channel — Bot Replies
- **Steps:** In a channel where the bot is installed, type `@[BotName] [question]` and send
- **Expected:** Bot replies in a thread under the message
- **Verify:** Reply is threaded (not a top-level post)

### B2. AI Label on Channel Reply
- **Steps:** Check the bot's threaded reply
- **Expected:** "AI generated" badge visible

### B3. Feedback Buttons on Channel Reply
- **Steps:** Check the bot's threaded reply
- **Expected:** Like/Dislike buttons present

### B4. No Streaming in Channels
- **Steps:** Send an @mention requiring a long response
- **Expected:** Response appears as a single message (no progressive updates, no Stop button)
- **Verify:** No typing dots or partial text visible during generation

### B5. Reply Threading
- **Steps:** Send multiple @mentions in the channel
- **Expected:** Each reply appears as a thread under its respective parent message

### B6. No Reply Without @Mention
- **Steps:** Send a message in the channel WITHOUT @mentioning the bot
- **Expected:** Bot does NOT reply. No thread created. Wait 15+ seconds to confirm.

### B7. @Mention Autocomplete
- **Steps:** Type `@` followed by the bot name in the channel compose box
- **Expected:** Bot appears in the mention suggestion picker with its description

---

## C. Group Chat Tests

### C1. @Mention in Group Chat
- **Steps:** Create a group chat, add the bot, send `@[BotName] hello`
- **Expected:** Bot replies in the group chat
- **Verify:** Typing indicator appears (unlike channels)

### C2. No Streaming in Group Chat
- **Steps:** Ask a question requiring a long response
- **Expected:** Response delivered as single message (no streaming in groups)

### C3. No Reply Without @Mention in Group
- **Steps:** Send a message without @mention
- **Expected:** Bot does NOT reply

---

## D. Access Control & Security

### D1. DM Allowlist Enforcement
- **Steps:** Send a DM from a user NOT in the allowlist
- **Expected:** Message is dropped silently. Server log shows `"dropping dm (not allowlisted)"`

### D2. Pairing Request Creation
- **Steps:** Send a DM from a new (non-allowlisted) user
- **Expected:** Server log shows `"msteams pairing request created"`. Request appears in `openclaw pairing list`

### D3. Pairing Approval
- **Steps:** Run `openclaw pairing approve [CODE]` on the server
- **Expected:** User can now send messages and receive replies

### D4. JWT Validation (Unauthenticated Request)
- **Steps:** `curl -X POST https://[endpoint]/api/messages -H "Content-Type: application/json" -d '{}'`
- **Expected:** Returns HTTP 401 with `{"error":"Unauthorized"}`

### D5. SSRF Guard (ServiceUrl Validation)
- **Server check:** `grep "serviceUrl" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log` — should not show rejected requests in normal operation

---

## E. Infrastructure

### E1. Gateway Running
- **Steps:** `sudo systemctl status openclaw-gateway`
- **Expected:** active (running)

### E2. msteams Provider Started
- **Steps:** `grep "msteams provider started" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`
- **Expected:** Shows port number (e.g. 3979)

### E3. Ports Listening
- **Steps:** `ss -tlnp | grep -E "3978|3979"`
- **Expected:** Both ports listed as LISTEN

### E4. HTTPS Endpoint Reachable
- **Steps:** `curl -s -o /dev/null -w "%{http_code}" -X POST https://[endpoint]/api/messages -H "Content-Type: application/json" -d '{}'`
- **Expected:** 401

### E5. Gateway Restart Recovery
- **Steps:** `sudo systemctl restart openclaw-gateway`, wait 15s, send a message
- **Expected:** Bot recovers and responds normally after restart

### E6. Server-Side Feedback Logging
- **Steps:** After submitting feedback, check server logs
- **Expected:** `grep "received feedback" /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log` shows entries

---

## F. Graph API & Media (Requires Configuration)

**Prerequisite:** Add Graph permissions to the Azure AD app registration:
- `Chat.Read` (application)
- `Files.ReadWrite.All` (application)
- `User.Read.All` (application)
Then grant admin consent.

### F1. Image Attachment Processing
- **Steps:** Send an image with text "What's in this image?"
- **Expected:** Bot describes the image content
- **Server check:** No `"graph media fetch empty"` in logs

### F2. File Attachment
- **Steps:** Send a document (PDF, DOCX) to the bot
- **Expected:** Bot acknowledges receiving the file

### F3. Bot Sending Files (File Consent)
- **Steps:** Ask the bot to create and send a file
- **Expected:** File Consent Card appears for user approval; file uploaded after consent

---

## G. Configuration Validation

### G1. Custom Prompt Starters
- **Steps:** Set `channels.msteams.welcomeCard.promptStarters` in config, restart, reinstall bot
- **Expected:** Welcome card shows custom prompt starters

### G2. Reply Style (Thread vs Top-Level)
- **Steps:** Set `channels.msteams.teams.[teamId].replyStyle` to "top-level", send @mention in channel
- **Expected:** Bot replies as a new top-level post, not a thread

### G3. Require Mention Override
- **Steps:** Set `channels.msteams.teams.[teamId].requireMention` to false
- **Expected:** Bot replies to all messages in that team without @mention

---

## Quick Smoke Test (5 minutes)

Run these 5 tests for a quick validation:
1. **A1** — Send "hi" in 1:1, verify reply
2. **A4** — Send long prompt, verify streaming
3. **A6** — Click thumbs up, verify feedback dialog
4. **B1** — @mention in channel, verify threaded reply
5. **E4** — curl endpoint, verify 401

---

## Test Reporting Guidelines

### Screenshots

Every test report MUST include a screenshot of the observed behavior for each test. Screenshots should be:

- Taken via Playwright `browser_take_screenshot` during the test run
- Named with the test ID: `{test-id}-{short-description}.png` (e.g. `A1-basic-reply.png`, `B1-channel-thread.png`)
- Saved to `teams/testing/screenshots/{report-date}/` (e.g. `teams/testing/screenshots/2026-03-23/`)
- Referenced in the report with relative paths: `![description](../screenshots/2026-03-23/A1-basic-reply.png)`

For tests verified via server logs or CLI (D1-D4, E1-E5), include the command output instead of a screenshot.

### Report File

- Save to `teams/testing/reports/{date}_{branch-short}_{commit-short}.md`
- Each test must have: Steps, Expected, Actual, and Screenshot/Evidence
- Use the template below as a starting point

### Template

```
# OpenClaw (INT) Teams Bot — Test Report

**Date:** YYYY-MM-DD
**Branch:** `branch-name`
**Commit:** `short-sha` (commit message)
**VM:** endpoint URL
**Bot:** bot name — App ID `app-id`
**Tested via:** Teams Web + Playwright browser automation

## Results Summary

| | Count |
|---|---|
| **Passed** | X/30 |
| **Not Tested** | Y/30 |
| **Failed** | Z/30 |

## A. 1:1 Personal Chat

### A1. Basic Reply — RESULT

- **Steps:** [what you did]
- **Expected:** [what should happen]
- **Actual:** [what happened]
- **Screenshot:** ![A1 basic reply](../screenshots/YYYY-MM-DD/A1-basic-reply.png)

[repeat for each test...]
```
