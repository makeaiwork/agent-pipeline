#!/bin/bash
# Notification hook: sends a notification when Claude needs attention

INPUT=$(cat)
MESSAGE=$(echo "$INPUT" | jq -r '.message // "Claude Code requires attention"' 2>/dev/null | tr -d '\r\n' | cut -c1-300)
# For the AppleScript string, escape the backslash and the quote, otherwise a quote in the message = code execution
AS_MESSAGE=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')

# macOS Desktop Notification
if command -v osascript &>/dev/null; then
  osascript -e "display notification \"$AS_MESSAGE\" with title \"Claude Code\" sound name \"Glass\"" 2>/dev/null || true
fi

# Linux Desktop Notification
if command -v notify-send &>/dev/null; then
  notify-send "Claude Code" "$MESSAGE" 2>/dev/null || true
fi

# === Optional: Slack Webhook ===
# Uncomment and set your webhook URL:
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
# if [ -n "$SLACK_WEBHOOK_URL" ]; then
#   curl -s -X POST "$SLACK_WEBHOOK_URL" \
#     -H 'Content-type: application/json' \
#     -d "{\"text\":\"Claude Code: $MESSAGE\"}" || true
# fi

# === Optional: Telegram Bot ===
# TELEGRAM_BOT_TOKEN="your-bot-token"
# TELEGRAM_CHAT_ID="your-chat-id"
# if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
#   curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
#     -d "chat_id=${TELEGRAM_CHAT_ID}&text=Claude Code: ${MESSAGE}" || true
# fi

exit 0
