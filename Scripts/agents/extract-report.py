# Print the last assistant message of a subagent transcript (JSONL), for reading an agent's final report.
# Usage: python3 extract-report.py <transcript.output> [max_chars]
import json, sys
path = sys.argv[1]
limit = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
last_text = None
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        msg = obj.get("message") if isinstance(obj, dict) else None
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            if content.strip():
                last_text = content
        elif isinstance(content, list):
            texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
            joined = "\n".join(t for t in texts if t.strip())
            if joined.strip():
                last_text = joined
print(last_text[:limit] if last_text else "NO TEXT FOUND")
