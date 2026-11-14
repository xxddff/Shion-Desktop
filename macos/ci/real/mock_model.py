"""A stand-in model for Hermes itself: an OpenAI-compatible endpoint that answers by script.

Hermes is pointed at it (model.provider custom, base_url http://127.0.0.1:9911/v1: inside.sh), so
a real gateway runs whole turns, tool calls included, with no network and no key. What it answers
is decided by the last message of the request:

  the result of a tool                      -> a short closing sentence
  a compaction's request for a summary      -> 前面聊过的事都记下了（mock 摘要）。, whatever the turns it
                                               summarizes say
  "给课程带个话"   (message_agent offered)   -> a message_agent call to @study
  "只通知课程"                               -> the same, wanting no answer (expects_reply false)
  "让课程别回"                               -> a message 课程's side answers with [SILENT]
  "问课程和通勤"                             -> one call to two teammates, with constraints
  "后台跑一下"     (terminal offered)        -> a terminal call in the background, told to notify
  "慢慢做"         (terminal offered)        -> a terminal call that takes three seconds: something can be
                                               put into the turn while it runs
  "说很多"                                   -> a reply of several megabytes in LONG_PARTS parts
  "慢慢说"                                   -> 第一段。 and, once the file GO is there, 第二段。: a reply
                                               that ends when a probe says so
  "长长地回"                                 -> a reply of LONG_REPLY characters, none of them twice: what a
                                               compaction has to summarize
  "给日记带个话" / "给跑腿带个话"             -> a message_agent call to @diary / @errand
  "慢慢等"         (terminal offered)        -> a terminal call that takes eight seconds: results that come
                                               meanwhile are folded into one turn
  "出个错"                                   -> a 400 the request is refused with: the turn fails
  "Message from 🤖 ..."                      -> 收到（mock）。 ([SILENT] when told to keep quiet)
  a background process's result             -> 后台的事有结果了（mock）。
  "[kanban] ..."                            -> 看板的事知道了（mock）。
  anything else                             -> 好（mock）。

A request whose last message says 满了 is answered as any other, with usage that says the context
holds FULL tokens, past the threshold of the profiles that compact by themselves (inside.sh); any
other answer says 100.

Every request is noted in LOG (one JSON line: what was asked with, what was answered).

  python mock_model.py [port] [log]"""
import json
import os
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9911
LOG = sys.argv[2] if len(sys.argv) > 2 else "mock-model.log"
MODEL = "mock-model"
# 「慢慢说」 goes on once this file is there (beside the log), or after SLOW_LONGEST seconds
GO = os.path.join(os.path.dirname(os.path.abspath(LOG)), "model-go")
SLOW = ("第一段。", "第二段。")
SLOW_LONGEST = 60.0
# a reply long enough that a viewer who stops reading falls more than Hermes keeps for it (4 MB a viewer,
# tui_gateway/transport.py FanoutTransport): 3000 parts of 1500 characters
# of 1500 characters. No two parts alike: Hermes cuts a stream that repeats itself (a runaway loop).
LONG_PARTS = 3000
LONG_PAUSE = 0.001
LONG_REPLY = 3000
FULL = 6000


def filler(index):
    dice = random.Random(index)
    return "".join(chr(dice.randint(0x4E00, 0x9FA5)) for _ in range(1490))
lock = threading.Lock()
count = [0]


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def decide(body):
    """(kind, value): ("text", str) | ("tool", (name, arguments)) | ("long", None)."""
    messages = body.get("messages") or []
    offered = {(tool.get("function") or {}).get("name") for tool in body.get("tools") or []}
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        return "text", "交代出去了（mock）。"
    said = text_of(last.get("content")) if last.get("role") == "user" else ""
    # a compaction's summary (agent/context_compressor.py): the turns it summarizes are in it, words
    # a rule below goes by among them
    if not offered and said.startswith("You are a summarization agent"):
        return "text", "前面聊过的事都记下了（mock 摘要）。"
    if "只通知课程" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "study", "message": "周五的课改到下午了（mock）", "expects_reply": False})
    if "问课程和通勤" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "study,commute", "message": "周五下午有空吗？（mock）",
                                          "constraints": "只说有或没有", "expecting": "一句话"})
    if "让课程别回" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "study", "message": "这条请保持沉默（mock）"})
    if "给日记带个话" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "diary", "message": "记一下今天的事（mock）"})
    if "给跑腿带个话" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "errand", "message": "顺路取个快递（mock）"})
    if "给课程带个话" in said and "message_agent" in offered:
        return "tool", ("message_agent", {"target": "study", "message": "下周的课表排好了吗？（mock）",
                                          "expecting": "一句话"})
    if "后台跑一下" in said and "terminal" in offered:
        return "tool", ("terminal", {"command": "sleep 4; echo mock-background-finished", "background": True,
                                     "notify_on_complete": True})
    if "慢慢做" in said and "terminal" in offered:
        return "tool", ("terminal", {"command": "sleep 3; echo mock-slow-finished"})
    if "慢慢等" in said and "terminal" in offered:
        return "tool", ("terminal", {"command": "sleep 8; echo mock-slow-finished"})
    if "出个错" in said:
        return "error", None
    if "说很多" in said:
        return "long", None
    if "长长地回" in said:
        return "text", "".join(chr(0x4E00 + (len(messages) * 131 + k * 17) % 20000) for k in range(LONG_REPLY))
    if "慢慢说" in said:
        return "slow", None
    if "Message from 🤖" in said and "保持沉默" in said:
        return "text", "[SILENT]"
    if "Message from 🤖" in said:
        return "text", "收到（mock）。"
    if "background process" in said.lower() or "process_complete" in said or "mock-background-finished" in said:
        return "text", "后台的事有结果了（mock）。"
    if "[kanban]" in said:
        return "text", "看板的事知道了（mock）。"
    return "text", "好（mock）。"


def wait_for_go():
    until = time.monotonic() + SLOW_LONGEST
    while not os.path.exists(GO) and time.monotonic() < until:
        time.sleep(0.02)


def note(body, kind, value):
    messages = body.get("messages") or []
    with lock:
        count[0] += 1
        line = {"n": count[0], "at": round(time.time(), 3), "stream": bool(body.get("stream")),
                "roles": [m.get("role") for m in messages][-6:],
                "last": text_of((messages[-1] if messages else {}).get("content"))[:600],
                "tools": sorted({(t.get("function") or {}).get("name") or "" for t in body.get("tools") or []}),
                "answer": kind if kind in ("long", "slow") else {kind: value}}
        with open(LOG, "a", encoding="utf-8") as out:
            out.write(json.dumps(line, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.reply(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "owned_by": "mock", "context_length": 200000}]})
        self.reply(404, {"error": {"message": "nothing here"}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.reply(404, {"error": {"message": "only chat completions"}})
        kind, value = decide(body)
        note(body, kind, value)
        if kind == "error":
            return self.reply(400, {"error": {"message": "mock refused this request", "type": "invalid_request_error"}})
        rid, made = f"chatcmpl-mock-{count[0]}", int(time.time())
        last = (body.get("messages") or [{}])[-1]
        full = last.get("role") == "user" and "满了" in text_of(last.get("content"))
        usage = {"prompt_tokens": FULL if full else 100, "completion_tokens": 10, "total_tokens": (FULL if full else 100) + 10}
        call = None
        if kind == "tool":
            call = {"id": f"call_mock_{count[0]}", "type": "function",
                    "function": {"name": value[0], "arguments": json.dumps(value[1], ensure_ascii=False)}}
        if not body.get("stream"):
            if kind == "slow":
                wait_for_go()
            words = "".join(f"第{i + 1}节。" for i in range(40)) if kind == "long" else "".join(SLOW) if kind == "slow" \
                else (value if kind == "text" else None)
            message = {"role": "assistant", "content": words}
            if call:
                message["tool_calls"] = [call]
            return self.reply(200, {"id": rid, "object": "chat.completion", "created": made, "model": MODEL,
                                    "choices": [{"index": 0, "message": message,
                                                 "finish_reason": "tool_calls" if call else "stop"}], "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def chunk(delta, finish=None, **more):
            payload = {"id": rid, "object": "chat.completion.chunk", "created": made, "model": MODEL,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}], **more}
            self.wfile.write(b"data: " + json.dumps(payload, ensure_ascii=False).encode() + b"\n\n")
            self.wfile.flush()

        try:
            chunk({"role": "assistant", "content": ""})
            if call:
                chunk({"tool_calls": [{"index": 0, **call}]})
                chunk({}, "tool_calls")
            elif kind == "long":
                for index in range(LONG_PARTS):
                    chunk({"content": f"第{index + 1}节。" + filler(index)})
                    time.sleep(LONG_PAUSE)
                chunk({}, "stop")
            elif kind == "slow":
                chunk({"content": SLOW[0]})
                wait_for_go()
                chunk({"content": SLOW[1]})
                chunk({}, "stop")
            else:
                for start in range(0, len(value), 3):
                    chunk({"content": value[start:start + 3]})
                chunk({}, "stop")
            self.wfile.write(b"data: " + json.dumps({"id": rid, "object": "chat.completion.chunk", "created": made,
                                                     "model": MODEL, "choices": [], "usage": usage}).encode() + b"\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
