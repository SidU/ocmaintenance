# Teams Plugin — Lessons Learned

Hard-won insights from bugs, reviews, and production incidents. Read this before making any msteams extension changes.

---

## #56040: Streaming + Tool Use — Silent Message Loss

**What happened:** PR #51808 added Teams streaming (progressive text updates via `streaminfo` entities). It worked perfectly for simple chatbot responses. But when an agent uses tools mid-response (text → tool calls → more text), the second text segment was silently lost or duplicated.

**Root cause:** `preparePayload()` used a one-shot `streamReceivedTokens` flag to decide whether the stream handled delivery. Once set to `true` by the first text segment, it never reset — so every subsequent `deliver()` call was suppressed, even for text segments the stream never saw.

**Why we missed it:**

1. **Tested the happy path only.** Streaming was validated with simple single-segment responses (user asks question → LLM responds with text). The multi-segment flow (text → tool call → more text) was never tested because it requires an agent with tools, not just a chatbot.

2. **State lifecycle wasn't scoped to segments.** The stream controller was designed with the assumption of one continuous text generation per reply. Tool-using agents break that assumption — they produce *discontinuous* text segments with tool calls in between. The `streamReceivedTokens` flag had reply-wide scope when it needed segment-wide scope.

3. **Silent failure mode.** When `preparePayload` returned `undefined`, the text was silently dropped — no error, no log, no fallback. If there had been a debug log on suppression (`log.debug("suppressing fallback: stream handled delivery")`), the bug would have been obvious in the first test run.

4. **No integration test for the multi-deliver path.** The `reply-dispatcher.test.ts` tests mocked `TeamsHttpStream` with `hasContent = false` (static), so the mock never reflected real state transitions. The `preparePayload` → called-twice path was untested.

**How to avoid this class of bug:**

- **Test state transitions, not just initial states.** Any time a function uses mutable flags to make decisions, write tests that call it multiple times and verify behavior changes between calls. The pattern is: `action1 → check → action2 → check`. A single-call test is necessary but not sufficient.

- **Scope state to its lifecycle.** When adding flags like `streamReceivedTokens`, ask: "what resets this?" If nothing resets it, it's either a one-shot (should be obvious from naming, e.g. `firstSegmentStreamed`) or a bug waiting for a multi-cycle caller.

- **Log on suppression.** Any time code silently drops/suppresses a payload, add a debug log. Silent drops are the hardest bugs to diagnose — you don't even know something went wrong.

- **Test with tools.** For any change to the reply pipeline (streaming, delivery, formatting), always test with a tool-using agent prompt, not just a simple chatbot prompt. Tool use is the most common source of multi-segment responses.

- **Test all call orderings, not just one sequence.** The stream controller has multiple entry points (`onPartialReply`, `preparePayload`, `finalize`) that mutate shared state. When fixing state bugs, enumerate the possible call sequences — e.g., `preparePayload → preparePayload` is different from `preparePayload → onPartialReply → preparePayload`. The first fix for #56040 handled one sequence but missed the other, caught in code review.

- **Test the contract, not just the bug.** When fixing a state machine bug, don't just reproduce the reported scenario and verify it passes. Ask: "what are all the possible inputs at each state?" Test the *full contract* of the changed function — all payload types (text-only, media-only, media+text), all cycle counts (1 round, 2 rounds, 3+ rounds), and all entry orderings. We kept testing the reproduction case instead of the contract of `preparePayload`, and a reviewer had to point out the missing edge cases (3+ segments, media+text after finalization).

---

## General Teams Streaming Protocol Gotchas

Things to keep in mind when working with the Teams `streaminfo` entity protocol:

1. **Monotonically growing content.** Teams requires each streaming chunk to be a prefix of subsequent chunks. If accumulated text changes shape (e.g., new text after tool calls replaces old text), Teams returns 403 `ContentStreamNotAllowed`.

2. **Stream finalization replaces typing activities.** The `type: "message"` final activity with `streamType: "final"` should replace the typing activities. If the streamId doesn't match or the timing is off, you get duplicate messages (one from typing activities, one from the final message).

3. **Informative updates establish the stream.** The first `sendInformativeUpdate` call returns a `streamId` that must be used for all subsequent chunks and the final message. If you lose this ID, the stream is orphaned.

4. **1 req/s rate limit.** Teams enforces roughly 1 request per second for streaming updates. The `DraftStreamLoop` throttles at 1500ms by default. Going faster causes 429s.

5. **4000 char limit.** Messages over 4000 chars cause `streamFailed = true` and early finalization. The `deliver()` fallback handles the full text in this case.

6. **Personal chats only.** Streaming is only enabled for `conversationType === "personal"`. Channels and group chats use the standard proactive messaging path (no `onPartialReply`).

---

## Testing Checklist for Reply Pipeline Changes

Before submitting any PR that touches `reply-stream-controller.ts`, `reply-dispatcher.ts`, `streaming-message.ts`, or the deliver/preparePayload flow:

- [ ] Unit test: single text segment (no tools) — stream delivers, fallback suppressed
- [ ] Unit test: multi-segment (text → tool → text) — first streamed, second via fallback
- [ ] Unit test: media payload — text suppressed, media delivered
- [ ] Unit test: stream failure (>4000 chars or network error) — fallback kicks in
- [ ] Unit test: non-personal chat (channel/group) — no streaming, all fallback
- [ ] Manual test A4: streaming progressive updates in 1:1 DM
- [ ] Manual test A5: streaming + tool use in 1:1 DM (both segments delivered)
- [ ] Manual test B4: no streaming in channels (single message delivery)

---

## Key Files Reference

| File | Role |
|------|------|
| `extensions/msteams/src/reply-stream-controller.ts` | Orchestrates stream lifecycle, `preparePayload` gating |
| `extensions/msteams/src/streaming-message.ts` | `TeamsHttpStream` — HTTP-level streaming protocol impl |
| `extensions/msteams/src/reply-dispatcher.ts` | Wires stream controller into the channel reply pipeline |
| `extensions/msteams/src/messenger.ts` | `sendMSTeamsMessages` — proactive messaging fallback |
