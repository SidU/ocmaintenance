# Teams Activity Events — Implementation Plan

**Goal:** Expose all incoming Teams Bot Framework activity types to OpenClaw as system events, so agents can observe and optionally act on them (e.g., welcome new members, react to reactions, track channel changes).

**Principle:** No auto-reply. Events are enqueued as system events that the agent sees as context in its next prompt. The agent decides whether to act, based on its instructions.

## Current State

The Teams extension (`extensions/msteams`) handles only 3 activity types:

1. **`message`** — full processing (auth, routing, dispatch to agent)
2. **`conversationUpdate`** — members added/removed (logged only, no action taken)
3. **`invoke`** with `fileConsent/invoke` — file upload consent flow

Everything else is silently dropped in `buildActivityHandler()` at `extensions/msteams/src/monitor.ts:343-356`.

## Teams Activity Types to Capture

| Activity Type | Sub-events | Use Cases |
|---|---|---|
| `conversationUpdate` | `membersAdded`, `membersRemoved`, `channelCreated`, `channelDeleted`, `channelRenamed`, `teamRenamed` | Welcome new members, announce departures, track channel changes |
| `messageReaction` | `reactionsAdded`, `reactionsRemoved` | Track emoji reactions on bot messages (feedback signal) |
| `installationUpdate` | `add`, `remove` | Know when bot is installed/uninstalled from a team |
| `messageUpdate` | (edited message) | Track when a user edits a message the bot processed |
| `messageDelete` | (deleted message) | Track when a user deletes a message |

## Model: How Discord Does It

Discord uses `enqueueSystemEvent()` from `src/infra/system-events.ts` — an in-memory queue that prefixes human-readable event text to the agent's next prompt. Pattern from `src/discord/monitor/listeners.ts`:

```typescript
// 1. Resolve which agent session this event belongs to
const route = resolveAgentRoute({ cfg, channel: "discord", peer: {...} });

// 2. Enqueue a human-readable system event
enqueueSystemEvent("Discord reaction added: 👍 by @user on #general msg 123", {
  sessionKey: route.sessionKey,
  contextKey: "discord:reaction:added:123:userId:👍",  // dedup key
});
```

The agent sees these events as context and decides whether to act.

## Implementation Steps

### 1. Extend `MSTeamsActivity` type

**File:** `extensions/msteams/src/sdk-types.ts`

Add missing fields the Bot Framework sends:

```typescript
reactionsAdded?: Array<{ type: string }>;
reactionsRemoved?: Array<{ type: string }>;
action?: string;  // for installationUpdate: "add" | "remove"
```

### 2. Extend `MSTeamsActivityHandler`

**File:** `extensions/msteams/src/monitor-handler.ts`

Add registration methods for new activity types:

```typescript
export type MSTeamsActivityHandler = {
  onMessage: (...) => MSTeamsActivityHandler;
  onMembersAdded: (...) => MSTeamsActivityHandler;
  onMembersRemoved: (...) => MSTeamsActivityHandler;
  onReactionsAdded: (...) => MSTeamsActivityHandler;
  onReactionsRemoved: (...) => MSTeamsActivityHandler;
  onConversationUpdate: (...) => MSTeamsActivityHandler;  // channel created/deleted/renamed
  onInstallationUpdate: (...) => MSTeamsActivityHandler;
  run?: (...) => Promise<void>;
};
```

### 3. Expand `buildActivityHandler()`

**File:** `extensions/msteams/src/monitor.ts`

Route all activity types to their registered handlers:

```typescript
async run(context) {
  switch (activityType) {
    case "message": // existing
    case "conversationUpdate": // dispatch to membersAdded/Removed + channel events
    case "messageReaction": // dispatch to reactionsAdded/Removed
    case "installationUpdate": // dispatch to install/uninstall
  }
}
```

### 4. Register event handlers in `registerMSTeamsHandlers()`

**File:** `extensions/msteams/src/monitor-handler.ts`

Each handler follows the Discord pattern:
- Resolve the agent route via `resolveAgentRoute()`
- Build a human-readable event description
- Call `enqueueSystemEvent()` with appropriate session key and dedup context key

#### Reactions example

```typescript
handler.onReactionsAdded(async (context, next) => {
  const activity = (context as MSTeamsTurnContext).activity;
  const reactions = activity.reactionsAdded ?? [];
  for (const reaction of reactions) {
    const route = resolveAgentRoute({
      cfg, channel: "msteams", peer: { kind, id: conversationId }
    });
    enqueueSystemEvent(
      `Teams reaction added: ${reaction.type} by ${activity.from?.name} in ${conversationType}`,
      {
        sessionKey: route.sessionKey,
        contextKey: `msteams:reaction:added:${activity.replyToId}:${activity.from?.id}:${reaction.type}`,
      }
    );
  }
  await next();
});
```

#### Member joins example (upgrade existing no-op)

```typescript
handler.onMembersAdded(async (context, next) => {
  const activity = (context as MSTeamsTurnContext).activity;
  const members = activity.membersAdded ?? [];
  for (const member of members) {
    if (member.id === activity.recipient?.id) continue; // skip bot itself
    const route = resolveAgentRoute({ cfg, channel: "msteams", ... });
    enqueueSystemEvent(
      `Teams member joined: ${member.name ?? member.id} in ${conversationName}`,
      {
        sessionKey: route.sessionKey,
        contextKey: `msteams:member:added:${conversationId}:${member.id}`,
      }
    );
  }
  await next();
});
```

### 5. Channel-level `conversationUpdate` sub-events

Teams sends channel lifecycle events within `conversationUpdate` via `channelData.eventType`:

```typescript
const channelData = activity.channelData;
if (channelData?.eventType === "channelCreated") {
  enqueueSystemEvent(`Teams channel created: ${channelData.channel?.name} in ${channelData.team?.name}`, ...);
} else if (channelData?.eventType === "channelDeleted") { ... }
else if (channelData?.eventType === "channelRenamed") { ... }
else if (channelData?.eventType === "teamRenamed") { ... }
```

## Files to Modify

| File | Change |
|---|---|
| `extensions/msteams/src/sdk-types.ts` | Add `reactionsAdded`, `reactionsRemoved`, `action` fields |
| `extensions/msteams/src/monitor-handler.ts` | Add handler registrations for new activity types |
| `extensions/msteams/src/monitor.ts` | Expand `buildActivityHandler()` to route all activity types |
| `extensions/msteams/src/monitor-handler/message-handler.ts` | Extract route resolution for reuse by event handlers |

## Future: Configuration

Could add a config option like Discord's `reactionNotifications`:

```yaml
channels:
  msteams:
    activityNotifications: "all"  # "off" | "own" | "all"
```

This controls which non-message events are surfaced to the agent.
