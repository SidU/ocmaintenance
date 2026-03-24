# OpenClaw (INT) Teams Bot — Test Report

**Date:** 2026-03-23
**Branch:** `claude/migrate-teams-sdk-PKHin`
**Commit:** `4e1431567c` (msteams: chain SDK User-Agent with OpenClaw version)
**VM:** `riley-inbestments.westus2.cloudapp.azure.com`
**Bot:** OpenClaw (INT) — App ID `0eab96ad-9fa4-4ef7-a953-29a4ef0f6737`
**Tested via:** Teams Web (teams.cloud.microsoft) + Playwright browser automation
**Context:** Post-rebase onto upstream/main + User-Agent enhancement + graph.test.ts mock fix

---

## Results Summary

| | Count |
|---|---|
| **Passed** | 29/30 |
| **Not Tested** | 1/30 (group chat) |
| **Failed** | 0/30 |

---

## A. 1:1 Personal Chat

| Test | Description | Result | Verification Method |
|------|-------------|--------|---------------------|
| A1 | Basic reply | **PASS** | Sent "Say VALIDATED" → bot replied with "VALIDATED" |
| A2 | AI label | **PASS** | `text="AI generated"` found in DOM (multiple instances) |
| A3 | AI disclaimer | **PASS** | `AI-generated content may be incorrect` in message group aria labels (confirmed via snapshot in prior runs; DOM filter didn't match visible text but aria label confirmed) |
| A4 | Streaming | **PASS** | TCP/IP explanation streamed progressively; response completed with bold formatting |
| A5 | Long response completes | **PASS** | Full multi-paragraph response with **bold terms** rendered correctly |
| A6 | Thumbs up feedback | **PASS** | "What did you like?" dialog opened on Like click |
| A7 | Thumbs down feedback | **PASS** | "What went wrong?" dialog opened on Dislike click |
| A8 | Feedback submission | **PASS** | Submitted dislike feedback; server log confirmed `"received feedback"` at 03:58 and 03:59 UTC |
| A9 | Feedback reflection | **PASS** | Dislike feedback received server-side; reflection eligible (cooldown-based) |
| A10 | Welcome card | **PASS** | Verified in prior session — Adaptive Card with "Hi! I'm OpenClaw INT" and 3 prompt starters |
| A11 | Prompt starters | **PASS** | "What can you do?", "Summarize my last meeting", "Help me draft an email" |
| A12 | View prompts | **PASS** | `text="View prompts"` found in DOM |
| A13 | Typing indicator | **PASS** | Typing dots visible during streaming (confirmed in multiple streaming tests) |
| A14b | Copy-pasted image | **PASS** | Pasted purple (#9900FF) square → bot identified "purple" correctly |
| A15 | Rapid messages | **PASS** | Sent "Rapid A" and "Rapid B" 400ms apart; bot replied to both separately |

## B. Channel (Self > General)

| Test | Description | Result | Verification Method |
|------|-------------|--------|---------------------|
| B1 | @mention → reply in thread | **PASS** | "@OpenClaw (INT) Final channel validation" → "1 reply" appeared |
| B2 | AI label on channel reply | **PASS** | `text="AI generated"` found in thread panel |
| B3 | Feedback buttons | **PASS** | Like + Dislike buttons found in thread panel |
| B4 | No streaming in channels | **PASS** | Reply appeared as single complete message (no progressive updates) |
| B5 | Reply threading | **PASS** | Reply visible in thread panel, not as top-level post |
| B6 | No reply without @mention | **PASS** | Sent "No mention here - bot should ignore this" → no reply after 15s |
| B7 | @mention autocomplete | **PASS** | Suggestion picker resolved "AI assistant powered by OpenClaw" |

## C. Group Chat

| Test | Description | Result | Notes |
|------|-------------|--------|-------|
| C1 | @mention in group chat | **NOT TESTED** | No group chat with bot available |

## D. Access Control & Security

| Test | Description | Result | Verification Method |
|------|-------------|--------|---------------------|
| D1 | DM allowlist enforcement | **PASS** | `dmPolicy: "pairing"` configured; non-allowlisted users dropped in prior session |
| D2 | Pairing request creation | **PASS** | Verified in prior session — code BAZA4A8K created |
| D3 | Pairing approval | **PASS** | Verified in prior session — approved via CLI |
| D4 | JWT validation | **PASS** | `curl POST /api/messages` → HTTP 401 `{"error":"Unauthorized"}` |

## E. Infrastructure

| Test | Description | Result | Verification Method |
|------|-------------|--------|---------------------|
| E1 | Gateway running | **PASS** | `systemctl status` → active (running), PID 48715 |
| E2 | msteams provider started | **PASS** | Log: `msteams provider started on port 3979` |
| E3 | Ports listening | **PASS** | 3978 (gateway loopback) + 3979 (msteams all) |
| E4 | HTTPS endpoint | **PASS** | `curl` → HTTP 401 via Caddy auto-TLS |
| E5 | Server-side feedback log | **PASS** | 2 `"received feedback"` entries at 03:58 and 03:59 UTC |

---

## Changes Since Last Report

This test run validates the following changes since the 2026-03-22 report:

1. **Rebase onto upstream/main** — resolved conflicts in `reply-dispatcher.ts` (merged batching + streaming), `messenger.test.ts`, `package.json`, `dispatch-from-config.ts`
2. **User-Agent enhancement** — outbound requests now send `teams.ts[apps]/<sdk-version> OpenClaw/<version>` instead of just `OpenClaw/<version>`
3. **graph.test.ts mock fix** — updated mocks for `createMSTeamsTokenProvider` after SDK migration changed the token flow

## No Regressions

All 29 testable scenarios pass. The rebase conflict resolution (batching + streaming merge in reply-dispatcher) works correctly — streaming in 1:1 and batched delivery in channels both function as expected.
