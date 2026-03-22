# Plan: Expose Teams Bot Framework APIs as OpenClaw Message Actions

## Context

The Teams extension currently exposes only **1 action** (`poll`). Slack exposes ~12 and Discord exposes ~35+. The Teams SDK Client (`@microsoft/teams.api`) has a rich API surface that we're barely using — only `conversations.activities(id).create()` for sending messages. We want to expose the full Bot Framework API as message actions so the AI agent can manage conversations, members, channels, and messages natively.

**Note:** `read` (fetching message history) is NOT available via Bot Framework REST API — it requires Graph API with `ChannelMessage.Read.All` permissions. We're excluding it from this phase.

## SDK API Surface (confirmed from `@microsoft/teams.api` v2.0.5 types)

### `client.conversations`
- `.activities(conversationId).create(params)` → send message (already used)
- `.activities(conversationId).update(activityId, params)` → edit message
- `.activities(conversationId).reply(activityId, params)` → reply to message
- `.activities(conversationId).delete(activityId)` → delete message
- `.activities(conversationId).members(activityId)` → list members of activity
- `.members(conversationId).get()` → list all members (`TeamsChannelAccount[]`)
- `.members(conversationId).getById(id)` → get single member
- `.create(params)` → create new conversation (1:1 or group)
- `.get(params)` → list conversations (paginated)

### `client.teams`
- `.getById(teamId)` → get team details (`TeamDetails`: id, name, type, aadGroupId, channelCount, memberCount)
- `.getConversations(teamId)` → list channels (`ChannelInfo[]`: id, name, type)

### `client.meetings`
- `.getById(meetingId)` → get meeting info
- `.getParticipant(meetingId, id)` → get meeting participant

## Actions to Implement

### Phase 1: Core Actions (this PR)

| Action Name | SDK Method | Notes |
|---|---|---|
| `member-info` | `client.conversations.members(convId).getById(userId)` | Returns TeamsChannelAccount (id, name, email, givenName, surname, userPrincipalName, objectId, userRole, tenantId) |
| `channel-list` | `client.teams.getConversations(teamId)` | Returns ChannelInfo[] (id, name, type). Requires teamId from channelData on inbound activity |
| `channel-info` | Individual channel details. Use `client.teams.getConversations(teamId)` + filter, or Graph API `/teams/{id}/channels/{id}` | Bot Framework only lists all; Graph can get one |
| `edit` | `client.conversations.activities(convId).update(activityId, params)` | Update a previously sent message |
| `delete` | `client.conversations.activities(convId).delete(activityId)` | Delete a previously sent message |
| `reply` | `client.conversations.activities(convId).reply(activityId, params)` | Reply to a specific message in a thread |

## Implementation Plan

### Step 1: Create Teams Bot API client wrapper
**New file:** `extensions/msteams/src/teams-bot-api.ts`

Thin wrapper functions around the SDK Client for each operation:
- `getConversationMembers(serviceUrl, conversationId, token)` → `TeamsChannelAccount[]`
- `getConversationMember(serviceUrl, conversationId, memberId, token)` → `TeamsChannelAccount`
- `getTeamChannels(serviceUrl, teamId, token)` → `ChannelInfo[]`
- `getTeamDetails(serviceUrl, teamId, token)` → `TeamDetails`
- `updateActivity(serviceUrl, conversationId, activityId, activity, token)` → `Resource`
- `deleteActivity(serviceUrl, conversationId, activityId, token)` → `void`
- `replyToActivity(serviceUrl, conversationId, activityId, activity, token)` → `Resource`

Each function instantiates `new sdk.Client(serviceUrl, { token, headers })` — same pattern as `sdk.ts:100-103`. We'll reuse `loadMSTeamsSdk()` and `buildUserAgent()`.

**Reuse from:**
- `extensions/msteams/src/sdk.ts` — `loadMSTeamsSdk()`, `MSTeamsTeamsSdk`
- `extensions/msteams/src/user-agent.ts` — `buildUserAgent()`
- `extensions/msteams/src/send-context.ts` — `resolveMSTeamsSendContext()` for getting adapter/token/serviceUrl

### Step 2: Create action gate config type
**Modify:** `extensions/msteams/src/channel.ts`

Add `MSTeamsActionConfig` type and `createMSTeamsActionGate()` following Discord's pattern in `src/discord/accounts.ts` and `src/channels/plugins/account-action-gate.ts`:

```typescript
type MSTeamsActionConfig = {
  messages?: boolean;      // edit, delete
  memberInfo?: boolean;    // member-info
  channelInfo?: boolean;   // channel-list, channel-info
  threads?: boolean;       // reply (thread reply)
};
```

Add `actions?: MSTeamsActionConfig` to the Teams config schema.

### Step 3: Create action handler
**New file:** `extensions/msteams/src/actions.ts`

Following the Discord pattern (`src/channels/plugins/actions/discord/handle-action.ts`):
- `handleMSTeamsMessageAction(ctx)` — main dispatcher
- Extract params using `readStringParam()` from plugin-sdk
- Resolve send context via `resolveMSTeamsSendContext()` to get serviceUrl + token
- Dispatch to bot API functions from Step 1
- Return `jsonResult()` style responses

### Step 4: Wire up in channel plugin
**Modify:** `extensions/msteams/src/channel.ts`

Update `actions.listActions()` to return the new actions based on action gates:
```typescript
listActions: ({ cfg }) => {
  if (!enabled) return [];
  const actions: ChannelMessageActionName[] = ["poll"];
  const gate = createMSTeamsActionGate(cfg);
  if (gate("messages")) actions.push("edit", "delete");
  if (gate("memberInfo")) actions.push("member-info");
  if (gate("channelInfo")) actions.push("channel-info", "channel-list");
  if (gate("threads")) actions.push("reply");
  return actions;
}
```

Update `handleAction()` to dispatch to the new handler.

### Step 5: Store teamId from inbound activities
**Modify:** `extensions/msteams/src/conversation-store.ts` (types) and `monitor-handler/message-handler.ts`

The `channel-list` and `channel-info` actions need the `teamId`, which comes from `activity.channelData.team.id` on inbound channel messages. We need to store this in the conversation reference so it's available for proactive calls.

Check if `StoredConversationReference` already captures `channelData` — if not, add `teamId?: string`.

### Step 6: Tests
**New file:** `extensions/msteams/src/teams-bot-api.test.ts`
**New file:** `extensions/msteams/src/actions.test.ts`

- Unit test bot API wrapper functions with mocked SDK Client
- Unit test action handler dispatching with mocked bot API functions
- Test action gate configuration

## Files to Create/Modify

| File | Action |
|---|---|
| `extensions/msteams/src/teams-bot-api.ts` | **Create** — Bot Framework API wrapper |
| `extensions/msteams/src/actions.ts` | **Create** — Action handler/dispatcher |
| `extensions/msteams/src/channel.ts` | **Modify** — Wire up actions, add config |
| `extensions/msteams/src/conversation-store.ts` | **Modify** — Add teamId to stored ref (if needed) |
| `extensions/msteams/src/monitor-handler/message-handler.ts` | **Modify** — Store teamId from channelData (if needed) |
| `extensions/msteams/src/teams-bot-api.test.ts` | **Create** — Bot API tests |
| `extensions/msteams/src/actions.test.ts` | **Create** — Action handler tests |

## Key Patterns to Follow

- **Action gate:** `src/channels/plugins/account-action-gate.ts` — `createAccountActionGate()`
- **Action handler:** `src/channels/plugins/actions/discord/handle-action.ts` — dispatcher pattern
- **Param extraction:** `readStringParam()`, `readNumberParam()` from plugin-sdk
- **Result format:** `jsonResult({ ok: true, ... })` pattern
- **SDK Client instantiation:** Same pattern as `sdk.ts:100-103`
- **Config schema:** `buildChannelConfigSchema()` from plugin-sdk

## Verification

1. `pnpm build` — type-check passes
2. `pnpm test --filter msteams` — all tests pass
3. `pnpm check` — lint/format passes
4. Manual test: send a message to the bot in Teams, then use the agent to:
   - `member-info` — get info about a conversation member
   - `channel-list` — list channels in the team
   - `edit` — edit a previously sent message
   - `delete` — delete a previously sent message
