#!/bin/bash
# paperclip-switch-provider.sh
#
# Bulk-toggle every agent in your Paperclip install between:
#   - Z.AI GLM Coding Plan subscription (via OpenCode's native zai-coding-plan provider)
#   - OpenRouter (via OpenCode's native openrouter provider)
#
# Why this exists: Paperclip's UI only lets you change the model on one agent
# at a time. If you're running a dozen+ agents and want to flip providers —
# e.g. to fail over from Z.AI to OpenRouter during an outage, or to test a
# different model across your whole fleet — clicking through every agent is
# painful. This script does it in one command by editing the agents.adapter_config
# JSONB column directly.
#
# USAGE
#   ./paperclip-switch-provider.sh zai                    # zai-coding-plan/glm-5.1
#   ./paperclip-switch-provider.sh zai glm-5              # zai-coding-plan/glm-5
#   ./paperclip-switch-provider.sh zai zai-coding-plan/glm-5-turbo
#   ./paperclip-switch-provider.sh openrouter             # openrouter/z-ai/glm-5.1
#   ./paperclip-switch-provider.sh openrouter openrouter/openai/gpt-oss-120b:free
#   ./paperclip-switch-provider.sh --status               # show current provider/model for all agents
#
# SETUP (before running for the first time)
#   1. Put your API keys in the environment before running, OR edit the
#      ZAI_KEY and OPENROUTER_KEY values below.
#
#         export ZAI_KEY="your-z.ai-api-key"
#         export OPENROUTER_KEY="sk-or-v1-..."
#
#   2. Confirm the DB_CONTAINER name matches your Paperclip Postgres
#      container. Default is docker-db-1 (the usual docker-compose name).
#      Check with:
#         docker ps --format '{{.Names}}' | grep -i postgres
#
#   3. Make it executable:
#         chmod +x paperclip-switch-provider.sh
#
# SAFETY
#   - Changes are written directly to Paperclip's Postgres database.
#   - Take a backup first if you care: pg_dump | gzip > backup.sql.gz
#   - The script only modifies agents.adapter_config — nothing else.
#   - If you run it with the wrong provider, run it again with the right one.
#
# REQUIREMENTS
#   - bash, docker, and a running Paperclip Postgres container
#   - psql (via docker exec — nothing needed on the host)

set -euo pipefail

# --- Configuration ----------------------------------------------------------

DB_CONTAINER="${PAPERCLIP_DB_CONTAINER:-docker-db-1}"
DB_USER="${PAPERCLIP_DB_USER:-paperclip}"
DB_NAME="${PAPERCLIP_DB_NAME:-paperclip}"

# Pull from env if set, otherwise fall back to placeholders you can edit in-file.
ZAI_KEY="${ZAI_KEY:-REPLACE_WITH_YOUR_ZAI_KEY}"
OPENROUTER_KEY="${OPENROUTER_KEY:-REPLACE_WITH_YOUR_OPENROUTER_KEY}"

DEFAULT_ZAI_MODEL="zai-coding-plan/glm-5.1"
DEFAULT_OPENROUTER_MODEL="openrouter/z-ai/glm-5.1"

# --- Helpers ----------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 <provider> [model]
       $0 --status

Providers:
  zai          Z.AI Coding Plan subscription (OpenCode's native zai-coding-plan provider)
  openrouter   OpenRouter (OpenCode's native openrouter provider)

Examples:
  $0 zai
  $0 zai glm-5
  $0 openrouter
  $0 openrouter openrouter/openai/gpt-oss-120b:free
  $0 --status
EOF
    exit 1
}

check_keys() {
    local provider="$1"
    case "$provider" in
        zai)
            if [ "$ZAI_KEY" = "REPLACE_WITH_YOUR_ZAI_KEY" ]; then
                echo "ERROR: ZAI_KEY is not set."
                echo "  Either export ZAI_KEY='your-z.ai-api-key' or edit this script."
                exit 1
            fi
            ;;
        openrouter)
            if [ "$OPENROUTER_KEY" = "REPLACE_WITH_YOUR_OPENROUTER_KEY" ]; then
                echo "ERROR: OPENROUTER_KEY is not set."
                echo "  Either export OPENROUTER_KEY='sk-or-v1-...' or edit this script."
                exit 1
            fi
            ;;
    esac
}

psql_exec() {
    docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" "$@"
}

# --- Status command ---------------------------------------------------------

if [ "${1:-}" = "--status" ]; then
    echo "Current provider/model for each agent:"
    echo
    psql_exec <<'SQL'
SELECT
  c.issue_prefix || '/' || a.name AS agent,
  COALESCE(a.adapter_config->>'model', '(default)') AS model,
  CASE
    WHEN a.adapter_config->>'model' LIKE 'zai-coding-plan/%' THEN 'zai (coding plan)'
    WHEN a.adapter_config->>'model' LIKE 'zai/%' THEN 'zai (pay-as-go)'
    WHEN a.adapter_config->>'model' LIKE 'openrouter/%' THEN 'openrouter'
    WHEN a.adapter_config->>'model' LIKE 'github-copilot/%' THEN 'github-copilot'
    ELSE 'other'
  END AS provider
FROM agents a
JOIN companies c ON a.company_id = c.id
ORDER BY c.issue_prefix, a.name;
SQL
    exit 0
fi

# --- Switch command ---------------------------------------------------------

PROVIDER="${1:-}"
MODEL="${2:-}"

case "$PROVIDER" in
    zai)
        check_keys zai
        MODEL="${MODEL:-$DEFAULT_ZAI_MODEL}"
        if [[ "$MODEL" != zai-coding-plan/* && "$MODEL" != zai/* ]]; then
            MODEL="zai-coding-plan/$MODEL"
        fi
        API_KEY_NAME="ZHIPU_API_KEY"
        API_KEY_VALUE="$ZAI_KEY"
        ;;
    openrouter)
        check_keys openrouter
        MODEL="${MODEL:-$DEFAULT_OPENROUTER_MODEL}"
        if [[ "$MODEL" != openrouter/* ]]; then
            MODEL="openrouter/$MODEL"
        fi
        API_KEY_NAME="OPENROUTER_API_KEY"
        API_KEY_VALUE="$OPENROUTER_KEY"
        ;;
    *)
        usage
        ;;
esac

echo "Switching all agents to: $PROVIDER"
echo "  model   = $MODEL"
echo "  env key = $API_KEY_NAME"
echo

# Step 1: clear any stale env vars from other providers so they don't
#         confuse OpenCode's provider-resolution logic on the next run.
psql_exec <<SQL
UPDATE agents SET adapter_config =
  adapter_config
    #- '{env,OPENROUTER_API_KEY}'
    #- '{env,ZHIPU_API_KEY}'
    #- '{env,OPENAI_BASE_URL}'
    #- '{env,OPENAI_API_KEY}';
SQL

# Step 2: ensure the env object exists on every agent (some might not have
#         one yet if they were created via the API with minimal config).
psql_exec <<SQL
UPDATE agents
SET adapter_config = jsonb_set(adapter_config, '{env}', '{}'::jsonb, true)
WHERE adapter_config->'env' IS NULL;
SQL

# Step 3: set the right api key binding and the model string.
psql_exec <<SQL
UPDATE agents
SET adapter_config = jsonb_set(
  jsonb_set(
    adapter_config,
    '{env,${API_KEY_NAME}}',
    '{"type": "plain", "value": "${API_KEY_VALUE}"}'::jsonb,
    true
  ),
  '{model}',
  to_jsonb('${MODEL}'::text),
  true
);
SQL

COUNT=$(psql_exec -t -A -c "SELECT COUNT(*) FROM agents WHERE adapter_config->>'model' = '${MODEL}';")
echo "Updated $COUNT agents to model $MODEL."
echo
echo "Run '$0 --status' to verify."
