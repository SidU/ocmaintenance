# Teams AI UX Improvements — Implementation Plan

**Date:** 2026-03-21
**Scope:** `extensions/msteams/` in openclaw/openclaw
**Reference:** [MS Teams AI UX Best Practices](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/teams-conversational-ai/ai-ux)

---

## Background

Microsoft has published mandatory requirements and best practices for bots that use AI in Teams. The OpenClaw Teams extension currently meets some (conversation history/context) but is missing several. This plan covers the items worth implementing, ranked by effort and impact.

---

## 1. AI-Generated Label

**Priority:** P0 (mandatory per MS guidelines, trivial to add)
**Effort:** Small (< 1 hour)
**Scope:** 1:1 chats, group chats, channels — all outbound messages

### What

Add `channelData.feedbackLoop` or the `ai` entity metadata to every AI-generated activity so Teams renders the "AI generated" badge automatically.

### How

In `messenger.ts` → `buildActivity()`, add to the activity object:

```ts
// Add AI-generated label (Teams renders a badge next to the message)
activity.channelData = {
  ...activity.channelData,
  feedbackLoopEnabled: false, // just the label, no feedback yet (see item 4)
};
// Entity-based AI label (newer SDK approach)
activity.entities = [
  ...(activity.entities ?? []),
  {
    type: "https://schema.org/Message",
    "@type": "Message",
    "@id": "",
    additionalType: ["AIGeneratedContent"],
  },
];
```

### Verification

- Send a message in a 1:1 chat → should show "AI generated" label below the message.
- Confirm label also appears in group chats and channels.

### Notes

- The exact metadata shape depends on the Bot Framework SDK version. Need to verify which format the Teams backend currently honors (entity-based vs. channelData). Test both; keep whichever works.
- This is purely additive — no behavior change.

---

## 2. Streaming Responses (1:1 chats only)

**Priority:** P1 (highest UX impact, mandatory per MS guidelines)
**Effort:** Medium-Large (multi-day)
**Scope:** 1:1 personal chats only (Teams limitation — streaming is not supported in group chats or channels as of March 2026)

### Current State

- The core already supports **block streaming**: the LLM emits partial text blocks via `onBlockReply`, and the reply dispatcher's `deliver` callback fires for each block.
- Currently, each block is sent as a **new, separate message** via `sendMSTeamsMessages()`.
- The typing indicator (`{ type: "typing" }`) is sent while waiting.

### Target State

In 1:1 chats, instead of sending multiple messages, **edit a single message in-place** as new blocks arrive, creating a progressive "streaming" effect.

### Implementation Plan

#### A. New streaming message manager

Create `extensions/msteams/src/streaming-message.ts`:

```ts
/**
 * Manages a single "streaming" message that gets updated in-place
 * as new text blocks arrive. Only for personal (1:1) chats.
 *
 * Flow:
 * 1. First block → sendActivity() to create message, capture activityId
 * 2. Subsequent blocks → updateActivity() to edit the same message
 * 3. Final → one last updateActivity() with complete text
 *
 * Handles:
 * - Buffering rapid-fire blocks (debounce updates to avoid 429s)
 * - Falling back to multi-message if updateActivity fails
 * - Adding a "typing" indicator (▍ cursor) during generation
 */
```

Key decisions:
- **Update debounce:** Teams rate-limits `updateActivity` calls. Buffer incoming text and flush on a timer (e.g., every 500–800ms). This is separate from the inbound debouncer.
- **Typing cursor:** Append `▍` to the message text during generation, strip on final update.
- **Failure fallback:** If `updateActivity` returns 4xx, fall back to sending remaining content as a new message (graceful degradation).

#### B. Wire into reply dispatcher

In `reply-dispatcher.ts` → `createMSTeamsReplyDispatcher()`:

- Detect conversation type from `conversationRef.conversation.conversationType`.
- If `personal` (1:1), create a `StreamingMessage` instance and pass it to the `deliver` callback.
- The `deliver` callback calls `streamingMessage.append(payload.text)` instead of `sendMSTeamsMessages()`.
- On dispatch idle (`markDispatchIdle`), call `streamingMessage.finalize()`.

#### C. Core integration points

The core's `createReplyDispatcherWithTyping` already calls `deliver()` for each block reply. No core changes needed — the Teams extension just needs to handle `deliver` differently for 1:1.

For group chats and channels, keep the current behavior (separate messages per block).

#### D. Bot Framework `updateActivity` usage

```ts
// In the turn context:
const response = await context.sendActivity({ type: "message", text: "Block 1..." });
const activityId = response.id;

// Later, update the same message:
await context.updateActivity({
  id: activityId,
  type: "message",
  text: "Block 1... Block 2...",
});
```

- **Important:** `updateActivity` requires the original `TurnContext`. The reply dispatcher creates a proactive conversation via `adapter.continueConversation()`. We need to ensure the `TurnContext` from the original inbound message is preserved and used for updates (not a new proactive context each time).
- Alternative: use `adapter.continueConversation()` with the conversation reference and call `turnCtx.updateActivity()` inside the callback. This should work for proactive updates.

#### E. Rate limiting & retry

- Teams enforces per-conversation rate limits on `updateActivity`. Expect 429s if updating too fast.
- Implement a minimum interval between updates (500ms recommended).
- On 429, respect `Retry-After` header and buffer until allowed.
- The existing retry infrastructure in `messenger.ts` (`sendWithRetry`, `classifyMSTeamsSendError`) can be reused.

#### F. Informative status updates

Before the LLM starts generating, send informative status messages:
- "Thinking..." → update to first text block
- If tool calls happen (web search, etc.), update with "Searching..." / "Reading..."

This requires hooking into tool-use events from the agent runner. Check if `replyOptions` already exposes tool events, or if a new callback is needed.

### Risks

- `updateActivity` may behave differently across Teams clients (desktop, web, mobile, iOS, Android). Need to test all.
- Rate limiting could cause dropped updates. The debounce buffer mitigates this.
- If the user sends a new message while streaming is in progress, the TurnContext may be invalidated. Need to handle this gracefully (finalize current stream, start new one).

---

## 3. Welcome Card / Prompt Starters

**Priority:** P1 (low effort, good UX)
**Effort:** Small (2–4 hours)
**Scope:** 1:1 chats (on first interaction), optionally group chats (on bot add)

### Current State

`monitor-handler.ts:155` explicitly skips welcome messages:
```ts
// Don't send welcome message - let the user initiate conversation.
```

### Implementation

#### A. Welcome card on bot install (1:1)

In `monitor-handler.ts` → `onMembersAdded`, when the bot itself is added to a 1:1 conversation, send an Adaptive Card:

```json
{
  "type": "AdaptiveCard",
  "version": "1.5",
  "body": [
    {
      "type": "TextBlock",
      "text": "Hi! I'm your OpenClaw assistant.",
      "weight": "bolder",
      "size": "medium"
    },
    {
      "type": "TextBlock",
      "text": "I can help you with questions, tasks, and more. Here are some things to try:",
      "wrap": true
    }
  ],
  "actions": [
    {
      "type": "Action.Submit",
      "title": "What can you do?",
      "data": { "msteams": { "type": "imBack", "value": "What can you do?" } }
    },
    {
      "type": "Action.Submit",
      "title": "Summarize my last meeting",
      "data": { "msteams": { "type": "imBack", "value": "Summarize my last meeting" } }
    },
    {
      "type": "Action.Submit",
      "title": "Help me draft an email",
      "data": { "msteams": { "type": "imBack", "value": "Help me draft an email" } }
    }
  ]
}
```

#### B. Configuration

- Make the welcome card opt-in/opt-out via config: `channels.msteams.welcomeCard: true | false` (default: `true`).
- Allow custom prompt starters via config: `channels.msteams.promptStarters: string[]`.
- If the agent has a custom persona/name, use that in the welcome text.

#### C. Group chat add

When the bot is added to a group chat, optionally send a simpler welcome:
> "Hi! Mention me with @BotName to get started."

Gate this behind `channels.msteams.groupWelcomeCard: true | false` (default: `false` to avoid being noisy).

---

## 4. Feedback Buttons with Reflective Learning Loop

**Priority:** P1 (differentiating feature — not just telemetry, but genuine self-improvement)
**Effort:** Medium (2–3 days)
**Scope:** All AI-generated responses

### What

Add thumbs-up/thumbs-down buttons after each AI-generated response via Teams' native `channelData.feedbackLoopEnabled`. On thumbs-down, trigger a **background reflection** where the agent reviews its response, derives a learning, and proactively messages the user with adjustments or clarifying questions.

### User-Facing Flow

```
User receives AI response
    ↓
User clicks 👎 (optionally adds a comment)
    ↓
Bot immediately acks: "Thanks for the feedback — I'll reflect on this."
    ↓ (background, non-blocking — does NOT block future messages)
Agent reflection runs asynchronously:
  - Reads recent session transcript + the thumbed-down response
  - Prompted to reflect on what could be improved
  - Derives a concise learning
    ↓
If meaningful adjustment found:
  → Proactive message via continueConversation():
    "I thought about your feedback. Going forward I'll [adjustment].
     Does that sound right, or would you like me to change something else?"
If minor/obvious:
  → No follow-up (learning stored silently)

On 👍:
  → Log silently (positive reinforcement, no user-facing action)
```

### Implementation

#### A. Enable feedback loop in activity metadata

In `messenger.ts` → `buildActivity()`:

```ts
activity.channelData = {
  ...activity.channelData,
  feedbackLoopEnabled: true,
};
```

This makes Teams show the native thumbs-up/thumbs-down UI on every AI-generated message.

#### B. Handle feedback invoke

When a user clicks thumbs-up/down, Teams sends an `invoke` activity with `name: "message/submitAction"`. Register a handler in `monitor-handler.ts`:

1. Parse the feedback payload (positive/negative + optional user comment + replyToId).
2. **Thumbs-up:** Log to session, no further action.
3. **Thumbs-down:** Log to session, then trigger background reflection (fire-and-forget).

```ts
// In the invoke handler (synchronous path — fast):
await context.sendInvokeResponse({ status: 200 });
// Ack to user:
await context.sendActivity("Thanks for the feedback — I'll reflect on this.");

// Background reflection (fire-and-forget, NOT awaited):
runFeedbackReflection({
  cfg, adapter, appId, conversationRef, tokenProvider,
  sessionKey, feedbackMessageId, userComment,
  log,
}).catch((err) => {
  log.error("feedback reflection failed", { error: String(err) });
});
```

#### C. Background reflection dispatch

New file: `extensions/msteams/src/feedback-reflection.ts`

```ts
export async function runFeedbackReflection(params: {
  cfg: OpenClawConfig;
  adapter: MSTeamsAdapter;
  appId: string;
  conversationRef: StoredConversationReference;
  tokenProvider?: MSTeamsAccessTokenProvider;
  sessionKey: string;
  feedbackMessageId: string;
  userComment?: string;
  log: MSTeamsMonitorLogger;
}) {
  const core = getMSTeamsRuntime();

  // 1. Read recent session transcript to get the thumbed-down response + context
  const recentTranscript = await readRecentSessionTranscript({
    storePath: core.channel.session.resolveStorePath(params.cfg.session?.store, {
      agentId: route.agentId,
    }),
    sessionKey: params.sessionKey,
    aroundMessageId: params.feedbackMessageId,
    contextLines: 10, // preceding messages for context
  });

  // 2. Build a synthetic reflection message
  const reflectionPrompt = buildReflectionPrompt({
    thumbedDownResponse: recentTranscript.targetMessage,
    precedingContext: recentTranscript.context,
    userComment: params.userComment,
  });

  // 3. Dispatch to the agent as a synthetic internal message
  //    The agent sees this as a new message in the same session,
  //    so it has full conversation context.
  const { dispatcher, replyOptions } = createMSTeamsReplyDispatcher({
    ...params,
    // Override deliver: capture the reflection output instead of sending directly
    // We want to inspect it before deciding whether to message the user
  });

  const result = await core.channel.reply.dispatchReplyFromConfig({
    ctx: buildReflectionContext(reflectionPrompt, params),
    cfg: params.cfg,
    dispatcher,
    replyOptions,
  });

  // 4. Extract the learning from the agent's response
  const learning = extractLearning(result);

  // 5. Store the learning in the session
  await storeSessionLearning({
    storePath,
    sessionKey: params.sessionKey,
    learning,
  });

  // 6. If the learning is meaningful, proactively message the user
  if (learning.shouldNotifyUser) {
    await sendProactiveReflectionMessage({
      adapter: params.adapter,
      appId: params.appId,
      conversationRef: params.conversationRef,
      message: learning.userFacingMessage,
      tokenProvider: params.tokenProvider,
    });
  }
}
```

#### D. Reflection prompt design

The synthetic message sent to the agent for reflection:

```
A user indicated your previous response wasn't helpful.

Your response was:
> [truncated response text, max ~500 chars]

Preceding context:
> [last 2-3 user messages for context]

User's comment: "[if provided]"

Briefly reflect: what could you improve? Consider tone, length,
accuracy, relevance, and specificity. Reply with:
1. A short adjustment note (1-2 sentences) for your future behavior
   in this conversation.
2. Whether you should follow up with the user (yes if the adjustment
   is non-obvious or you have a clarifying question; no if minor).
3. If following up, draft a brief message to the user.
```

#### E. Feedback persistence and session learnings

##### Raw feedback events (for mining)

Append every feedback event (positive and negative) to the session transcript JSONL (`sessions/*.jsonl`) using the existing `type: "custom"` convention (not a new top-level type). All JSONL parsers in the codebase (`session-cost-usage.ts`, `memory/session-files.ts`, etc.) filter on `type === "message"` with `role === "user" | "assistant"` and skip everything else — so `custom` events are safely ignored. This matches how other non-message events (tool calls, etc.) are already stored.

```jsonl
{"type":"custom","event":"feedback","ts":1711036800000,"messageId":"1711036790000","value":"negative","comment":"too verbose","sessionKey":"msteams:abc123","agentId":"default","conversationId":"19:xyz"}
{"type":"custom","event":"feedback","ts":1711037100000,"messageId":"1711037050000","value":"positive","sessionKey":"msteams:abc123","agentId":"default","conversationId":"19:xyz"}
```

Fields:
- `type: "custom"`, `event: "feedback"` — follows existing convention for non-message events
- `ts` — timestamp of the feedback action
- `messageId` — the Teams activity ID of the thumbed-down/up response
- `value` — `"positive"` | `"negative"`
- `comment` — optional free-text from the user (Teams supports this in the feedback UI)
- `sessionKey` / `agentId` / `conversationId` — for aggregation queries
- `reflectionLearning` — (added after reflection completes) the derived learning, if any

**Mining later:**
- Simple: `grep '"event":"feedback"' ~/.openclaw/agents/*/sessions/*.jsonl`
- Aggregation script: group by agentId, sessionKey, or time window to spot patterns (e.g., "users consistently thumbs-down long responses", "agent X gets 3x more negative feedback")
- Dashboard: could feed into a Grafana/Kibana pipeline if session logs are shipped to a log aggregator

##### Session learnings (for real-time injection)

Separate from the raw feedback log, store **derived learnings** that the agent should act on:

**Storage:** Add a `learnings: string[]` field to the session entry, or use a companion file (e.g., `<sessionKey>.learnings.json`).

**Injection:** In `get-reply-run.ts`, when building `extraSystemPrompt`, append stored learnings:

```ts
// In the extraSystemPrompt construction:
const sessionLearnings = await loadSessionLearnings(storePath, sessionKey);
if (sessionLearnings.length > 0) {
  extraParts.push(
    "## Session Learnings (from user feedback)\n" +
    sessionLearnings.map((l) => `- ${l}`).join("\n")
  );
}
```

This means on every future message in the same session, the agent sees its own learnings and adjusts behavior without any explicit re-prompting.

##### Two-tier design rationale

Raw feedback events and derived learnings are kept separate because they serve different purposes:
- **Raw events** are immutable audit records for offline analysis. Every thumbs-up/down is recorded regardless of whether a reflection runs.
- **Learnings** are the actionable output of reflections — curated, concise, and injected into the agent's context. They can be edited, removed, or expire without affecting the audit trail.

#### F. Proactive follow-up message

When the agent determines the adjustment is worth communicating:

```ts
async function sendProactiveReflectionMessage(params) {
  // Uses existing proactive messaging infrastructure
  await sendMSTeamsMessages({
    replyStyle: "top-level",
    adapter: params.adapter,
    appId: params.appId,
    conversationRef: params.conversationRef,
    messages: [{ text: params.message }],
    retry: {},
  });
}
```

Example user-facing message:
> "I thought about your feedback. I was being too verbose with caveats — going forward I'll keep responses direct and actionable. Let me know if you'd like me to adjust anything else."

#### G. Safeguards

- **Rate limit reflections:** Max 1 reflection per session per 5 minutes (prevent feedback spam from triggering excessive LLM calls).
- **No reflection loops:** Mark reflection messages as internal — if the user thumbs-down the reflection follow-up, log it but don't trigger another reflection.
- **Token budget:** Cap the reflection prompt + transcript context to ~2000 tokens to keep cost low.
- **Graceful failure:** If reflection fails (LLM error, timeout), log and move on — the ack was already sent.

### Configuration

- `channels.msteams.feedbackEnabled: true | false` (default: `true`) — enables thumbs UI.
- `channels.msteams.feedbackReflection: true | false` (default: `true`) — enables the reflection loop (can disable to just log feedback without reflection).
- `channels.msteams.feedbackReflectionCooldownMs: number` (default: `300000` / 5 min) — minimum interval between reflections per session.

---

## 5. Suggested Actions (Follow-up Prompts)

**Priority:** P3 (nice to have, depends on agent capability)
**Effort:** Medium (requires agent-side changes)
**Scope:** 1:1 chats (suggested actions render as pills above the compose box)

### What

After each response, suggest 2–3 follow-up prompts as clickable buttons.

### Implementation Options

#### Option A: Agent-generated suggestions

The agent returns suggested follow-ups in its response metadata. The Teams extension extracts these and adds them as `suggestedActions` on the activity:

```ts
activity.suggestedActions = {
  actions: [
    { type: "imBack", title: "Tell me more", value: "Tell me more" },
    { type: "imBack", title: "Show an example", value: "Show an example" },
  ],
};
```

This requires the agent/LLM to generate suggestions — may need prompt engineering or a separate lightweight LLM call.

#### Option B: Static contextual suggestions

Based on conversation state (first message, follow-up, etc.), offer pre-configured suggestions. Simpler but less useful.

**Recommendation:** Defer this until the agent pipeline supports suggestion generation. It's not a mandatory requirement.

---

## 6. SSO (Azure AD Single Sign-On)

**Priority:** P3 (nice to have, only needed for user-context actions)
**Effort:** Large
**Scope:** User authentication flow

### Current State

The bot authenticates itself (client credentials flow) to call Graph API for file operations. There's no user-facing sign-in flow.

### When Needed

Only if the agent needs to act on behalf of the user (e.g., read their calendar, send email as them). Currently not required for OpenClaw's use case.

**Recommendation:** Defer unless a specific user-context feature requires it.

---

## 7. App Manifest — `copilotAgents` Node

**Priority:** P4 (only for Teams Store distribution)
**Effort:** Small (manifest change only)
**Scope:** App manifest (external to this repo)

### What

Add `copilotAgents.customEngineAgents` to the Teams app manifest to register as a "custom engine agent" in the Teams Store.

### When Needed

Only if distributing through the Teams Store / Microsoft 365 admin center. For self-hosted deployments, not required.

**Recommendation:** Document how to add this for users who want Store distribution, but don't include in the default setup.

---

## Implementation Order

| Phase | Items | Dependencies |
|-------|-------|-------------|
| **Phase 1** | AI Label (#1) | None |
| **Phase 2** | Welcome Card (#3) | None |
| **Phase 3** | Feedback + Reflective Learning (#4) | AI Label should be in place first. Needs `extraSystemPrompt` injection point for learnings (small core addition in `get-reply-run.ts`). |
| **Phase 4** | Streaming (#2) | Needs careful testing across Teams clients. Independent of feedback. |
| **Later** | Suggested Actions (#5), SSO (#6), Manifest (#7) | Agent pipeline changes / specific need |

**Note:** Feedback (#4) moved ahead of Streaming (#2) because it's a differentiating feature (self-improving agent) vs. streaming which is standard table-stakes UX. Both are P1 but feedback is more novel.

---

## Key Constraints

- **Streaming is 1:1 only:** As of March 2026, Teams streaming bot messages only work in one-on-one (personal) chats. Group chats and channels do not support `updateActivity`-based streaming. The extension must detect conversation type and only use streaming in personal chats.
- **Rate limits:** Teams enforces per-conversation rate limits on both `sendActivity` and `updateActivity`. The streaming implementation must respect these.
- **Bot Framework version:** The current extension uses a custom lightweight adapter (not the full Bot Framework SDK). Some features (like `updateActivity`) may need additions to the adapter interface in `messenger.ts` / `sdk-types.ts`.
- **Core changes needed for feedback learnings:** The `extraSystemPrompt` injection in `get-reply-run.ts` needs a small addition to load and append session learnings. This is the only core change across Phases 1–3. Everything else is extension-side.
- **Reflection is fire-and-forget:** The background reflection must not block the user's next message. It runs as an unawaited promise with error catching. The ack ("Thanks for the feedback") is sent synchronously in the invoke handler before the reflection starts.
- **No cron needed:** Reflections are event-driven (triggered by thumbs-down invoke), not scheduled. The proactive follow-up uses the existing `continueConversation()` path.

---

## Testing Strategy

The extension's existing tests use lightweight stubs (mock adapters, recorded `sendActivity` sinks, `vi.mock` for Graph uploads, `setMSTeamsRuntime()` for runtime injection). New tests follow the same patterns.

### Per-Feature Unit Tests

#### Phase 1: AI Label

**File:** `messenger.test.ts` (extend existing)

- `buildActivity()` includes AI-generated entity metadata on every outbound activity
- `buildActivity()` sets `channelData.feedbackLoopEnabled` when feedback is enabled
- Entity metadata doesn't interfere with existing mention entities (both should coexist in `activity.entities`)
- Media-only messages (no text) still get the AI label

#### Phase 2: Welcome Card

**File:** new `welcome-card.test.ts`

- `onMembersAdded` sends Adaptive Card when bot is added to a 1:1 conversation
- `onMembersAdded` does NOT send a card when a non-bot member is added
- Welcome card is suppressed when `channels.msteams.welcomeCard: false`
- Custom prompt starters from config are used when provided
- Group chat welcome respects `groupWelcomeCard` config (default: off)

#### Phase 3: Feedback + Reflection

**Files:** new `feedback-reflection.test.ts`, extend `messenger.test.ts`

Feedback invoke handling:
- Thumbs-up invoke → logs `custom/feedback` event to session JSONL, no reflection triggered
- Thumbs-down invoke → logs event AND fires background reflection (verify via spy)
- Invoke handler returns 200 immediately (does not await reflection)
- Feedback with optional user comment → comment included in logged event
- Malformed invoke payload → gracefully ignored, logged as warning

Reflection dispatch:
- Reflection prompt includes truncated response text + preceding context
- Reflection is skipped if cooldown hasn't elapsed (rate limiting)
- Reflection failure → error logged, no user-facing message, no throw
- Reflection marked as internal → thumbs-down on reflection follow-up does NOT trigger nested reflection

Session learnings:
- Derived learning is stored in session entry
- Learnings are injected into `extraSystemPrompt` on next message in same session
- Empty learnings list → no `## Session Learnings` section added
- Multiple learnings accumulate correctly

Proactive follow-up:
- `shouldNotifyUser: true` → proactive message sent via `continueConversation()`
- `shouldNotifyUser: false` → learning stored silently, no message sent

#### Phase 4: Streaming

**File:** new `streaming-message.test.ts`

- First text block → `sendActivity()` called, activityId captured
- Subsequent blocks → `updateActivity()` called with accumulated text + typing cursor (`▍`)
- Finalize → `updateActivity()` with complete text, no cursor
- Rapid blocks within debounce window → batched into single `updateActivity()`
- `updateActivity()` failure → falls back to new `sendActivity()` for remaining content
- Only activates for `conversationType === "personal"` — group/channel uses existing multi-message path
- Rate limit (429) on `updateActivity` → respects retry-after, buffers content

### Integration / E2E Considerations

Unit tests cover the logic, but these features touch the live Teams Bot Framework API. Things that **can't be fully unit-tested** and need manual verification on a real Teams tenant:

| Feature | What to verify manually |
|---------|------------------------|
| AI Label | Badge renders on desktop, web, mobile (iOS, Android) |
| Welcome Card | Card renders on bot install, action buttons send `imBack` messages |
| Streaming | Progressive text updates visible in real-time, cursor disappears on completion |
| Feedback | Native thumbs UI appears, clicking triggers invoke, user comment form works |
| Reflection follow-up | Proactive message arrives after delay, not during active typing |

### Test commands

```bash
# Run just the msteams extension tests
pnpm test -- extensions/msteams

# Run a specific test file
pnpm test -- extensions/msteams/src/messenger.test.ts

# With coverage
pnpm test:coverage -- extensions/msteams
```
