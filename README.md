# Paperclip + Z.AI GLM Coding Plan

**The missing setup guide for running [Paperclip](https://github.com/paperclipai/paperclip) AI agents on Z.AI's GLM Coding Plan subscription.**

If you just bought a [Z.AI GLM Coding Plan](https://z.ai/subscribe?ic=B9MR9ZI3Y) and your Paperclip agents are throwing `error 1113: Insufficient balance or no resource package` — or the model validator is rejecting everything except `github-copilot/*` — this is the fix. Took me most of a day to figure out. Hope it saves you the time.

> **Disclosure:** the Z.AI link above is my affiliate link. Same $18/month for you either way; I get a small kickback if you use it. If you'd rather skip it, just go to [z.ai](https://z.ai) directly — the fix below works either way.

---

## TL;DR — three things you'll probably get wrong

| Wrong | Right |
|---|---|
| Endpoint: `api.z.ai/api/paas/v4` | Endpoint: `api.z.ai/api/coding/paas/v4` |
| Env var: `OPENAI_API_KEY` / `ZAI_API_KEY` | Env var: **`ZHIPU_API_KEY`** |
| Model: `glm-5.1` | Model: **`zai-coding-plan/glm-5.1`** |

Fix all three and it just works.

## The working config

In Paperclip's agent configuration (either via the UI or the `agents.adapter_config` JSON):

```json
{
  "model": "zai-coding-plan/glm-5.1",
  "env": {
    "ZHIPU_API_KEY": {
      "type": "plain",
      "value": "<your-z.ai-api-key>"
    }
  }
}
```

No `OPENAI_BASE_URL` override. No source patches. No middleware. Paperclip's OpenCode adapter already knows about the `zai-coding-plan` provider — you just need to give it the right env var.

## Why each of those three things matters

### Endpoint: two separate billing paths

Z.AI runs two API endpoints that look nearly identical but bill differently:

- `https://api.z.ai/api/paas/v4` — pay-as-you-go, needs pre-loaded credits
- `https://api.z.ai/api/coding/paas/v4` — the Coding Plan subscription

Even with an active subscription, your balance at the pay-as-you-go endpoint is `$0`. Hit it and you get error 1113 every time, even though your dashboard says the plan is active.

### Env var: OpenCode has its own provider catalog

I spent hours trying to trick OpenCode into treating Z.AI as an OpenAI-compatible endpoint by setting `OPENAI_BASE_URL=https://api.z.ai/...`. OpenCode doesn't work that way. It ships with a baked-in providers catalog, and each provider expects its own env var. The Z.AI provider expects `ZHIPU_API_KEY`. Setting `OPENAI_API_KEY` does nothing for Z.AI calls.

### Model prefix: OpenCode has *three* Z.AI providers

OpenCode's provider catalog actually contains three separate Z.AI entries, each pointing at a different endpoint:

```
zai/*               →  api.z.ai/api/paas/v4         (pay-as-you-go)
zai-coding-plan/*   →  api.z.ai/api/coding/paas/v4  (subscription) ← this one
zhipuai/*           →  open.bigmodel.cn/api/paas/v4 (China-mainland)
```

Your agent's `model` field needs the `zai-coding-plan/` prefix. Passing just `glm-5.1` fails because OpenCode has no idea which provider to route to.

## Verify it works before pointing real agents at it

Shell into your Paperclip server container and run:

```bash
ZHIPU_API_KEY=<your-key> opencode run \
  --model zai-coding-plan/glm-5.1 \
  --format json \
  "Reply with just the word hello."
```

**Expected:** a `text` event containing `"hello"`, `"cost": 0`, and (nice bonus) `"cache.read"` showing thousands of tokens. That's confirmation that:

1. Your auth works
2. The subscription is active and billing correctly
3. Z.AI's native cache layer is engaged

**If you still see error 1113**, your subscription hasn't propagated yet. Community reports suggest 5–15 minutes after purchase, even though Z.AI's dashboard marks the plan as active immediately. Wait a bit and retry.

## Bulk-switching all your agents at once

Paperclip's UI only lets you change models one agent at a time. If you're running a dozen+ agents and want to flip them all at once — or toggle back to OpenRouter for failover — there's a helper script at [`scripts/paperclip-switch-provider.sh`](scripts/paperclip-switch-provider.sh).

Set your API keys at the top of the file, then:

```bash
./paperclip-switch-provider.sh zai              # Switch everything to zai-coding-plan/glm-5.1
./paperclip-switch-provider.sh zai glm-5        # Specific model
./paperclip-switch-provider.sh openrouter       # Fail back to openrouter/z-ai/glm-5.1
./paperclip-switch-provider.sh --status         # See what every agent is currently on
```

It updates the `adapter_config` JSONB column directly in your Paperclip Postgres database, handling env var cleanup between providers so you never end up with stale keys confusing OpenCode.

### What `--status` looks like once it's working

```
Current provider/model for each agent:

               agent                |          model          |     provider
------------------------------------+-------------------------+-------------------
 ALE/Affiliate Marketing Agent      | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/CEO                            | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Community Retention Manager    | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Content Ops Editor             | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Founding Engineer              | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Funnel Automation Engineer     | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Growth Offer Strategist        | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/OpenRouter Model Auditor       | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Partnerships Affiliate Manager | zai-coding-plan/glm-5.1 | zai (coding plan)
 ALE/Substack Publisher             | zai-coding-plan/glm-5.1 | zai (coding plan)
 MIR/CEO                            | zai-coding-plan/glm-5.1 | zai (coding plan)
 MIR/Founding Engineer              | zai-coding-plan/glm-5.1 | zai (coding plan)
 MIR/Growth Lead                    | zai-coding-plan/glm-5.1 | zai (coding plan)
 PIC/COO                            | zai-coding-plan/glm-5.1 | zai (coding plan)
 PIC/Content & SEO Strategist       | zai-coding-plan/glm-5.1 | zai (coding plan)
 PIC/Founding Engineer              | zai-coding-plan/glm-5.1 | zai (coding plan)
 PIC/Sales & Growth Lead            | zai-coding-plan/glm-5.1 | zai (coding plan)
 PIC/Support & Knowledge Manager    | zai-coding-plan/glm-5.1 | zai (coding plan)
```

*(Real output from my install running 3 companies and ~20 agents, all happily billing against one flat subscription.)*

## Why it's worth the setup hassle

Coding Plan is a **flat-rate subscription**. Once the wiring works, every API call is effectively free at the margin. You can point the full firehose of Paperclip's heartbeat runs at `zai-coding-plan/glm-5.1` without watching a per-token meter.

Z.AI's native cache layer is included — I see 7-8K tokens cache-hit on repeat runs out of the box, which cuts effective latency and makes the subscription even more of a bargain.

**Compared to `openrouter/z-ai/glm-5.1`** (same underlying model, routed through OpenRouter's per-token markup), the subscription is clearly the right call for anyone doing real heartbeat-driven agent work. I went from ~$5/day in OpenRouter token spend back down to effectively `$0`.

## Related projects

- **[Paperclip](https://github.com/paperclipai/paperclip)** — the AI agent orchestration platform this fix is for
- **[paperclip-vision](https://github.com/aronprins/paperclip-vision)** by [Aron Prins](https://github.com/aronprins) — a Claude Code skill that interviews you and produces `VISION.md` + `CEO_BOOTSTRAP.md` so your Paperclip CEO agent has a real mandate instead of guessing. Nice complement to this one — fix your model routing here, fix your agent strategy there. Aron's an active Paperclip contributor and worth following.
- **[Z.AI GLM Coding Plan](https://z.ai/subscribe?ic=B9MR9ZI3Y)** — $18/month flat rate for GLM-5.1 and siblings *(affiliate link — same price for you, small kickback for me)*
- **[OpenCode](https://opencode.ai)** — the CLI adapter Paperclip uses; the `zai-coding-plan` provider definition lives in its models catalog

## Who I am

I'm Nicholas. I write about building and running AI-assisted businesses at **[nicholasrhodes.substack.com](https://nicholasrhodes.substack.com/)** and I'm building **[MirrorMemory](https://mirrormemory.ai)**. If this doc saved you an afternoon, come say hi.

## License

MIT. Use it however you want. Pull requests welcome if Z.AI changes anything.
