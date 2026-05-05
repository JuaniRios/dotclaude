---
allowed-tools: Bash(source:*), Bash(python3:*), Bash(cat:*), Read, Write
description: Format and send a message to Telegram via the bot API. Accepts a message description or content and formats it with Telegram HTML for pasting in group chat.
argument-hint: "<message description or content>"
---

# Telegram Message — send formatted messages to Telegram

Takes a message (provided inline or from conversation context) and sends it
to the user via the Telegram bot API with proper HTML formatting.

## Step 1 — Determine the message content

Parse the argument for the message content or description. If the argument
describes what to send (e.g., "send the stuck redemptions table"), look back
in the conversation for the relevant data and compose the message.

If no argument is provided, ask what to send.

## Step 2 — Format the message

Format using Telegram HTML:

- `<b>text</b>` for headers and emphasis
- `<code>text</code>` for IDs, hashes, technical values
- `<a href="url">text</a>` for hyperlinks
- Plain `-` for bullets
- Blank lines between sections
- Escape `<`, `>`, `&` in content text (not in tags)

Keep the message concise and scannable. Use emoji prefixes for section
headers when appropriate.

## Step 3 — Show draft and confirm

Print the formatted message to the terminal so the user can review it.
Ask for approval or edits before sending.

## Step 4 — Send via Telegram

Credentials are in `~/.config/telegram-bot.env` (contains
`export TELEGRAM_BOT_TOKEN=...` and `export TELEGRAM_CHAT_ID=...`).

1. Write the message to `/tmp/telegram-message.txt`
2. Send it:

```bash
source ~/.config/telegram-bot.env
python3 -c "
import os, urllib.request, urllib.parse, json

with open('/tmp/telegram-message.txt') as f:
    text = f.read()

token = os.environ['TELEGRAM_BOT_TOKEN']
chat_id = os.environ['TELEGRAM_CHAT_ID']
url = f'https://api.telegram.org/bot{token}/sendMessage'
data = urllib.parse.urlencode({
    'chat_id': chat_id,
    'text': text,
    'parse_mode': 'HTML'
}).encode()
req = urllib.request.Request(url, data)
resp = json.load(urllib.request.urlopen(req))
if resp.get('ok'):
    print('Sent to Telegram')
else:
    print(f'Telegram error: {resp}')
"
```

3. Print confirmation: "Message sent to Telegram."

## Hard rules

1. Always show the draft to the user before sending.
2. Never send without explicit approval.
3. Use Telegram HTML parse mode — not MarkdownV2.
4. Keep messages concise and scannable.
5. If `telegram-bot.env` is missing or send fails, print the formatted
   message and tell the user to copy-paste manually.
