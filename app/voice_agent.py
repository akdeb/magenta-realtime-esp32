#!/usr/bin/env python3
import json
import math
import re
import sys
import time
from pathlib import Path

import numpy as np
from huggingface_hub import snapshot_download


SAMPLE_RATE = 16000
SAMPLE_WIDTH = 2
CHUNK_BYTES = 2048
START_RMS = 95.0
END_RMS = 70.0
MIN_SPEECH_SEC = 0.35
END_SILENCE_SEC = 0.85
MAX_SPEECH_SEC = 8.0


def emit(payload):
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def rms_i16(pcm):
    if len(pcm) < SAMPLE_WIDTH:
        return 0.0
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
    if samples.size == 0:
        return 0.0
    return float(math.sqrt(float(np.mean(samples * samples))))


def pcm_to_float32(pcm):
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
    return samples / 32768.0


def extract_json_array(text):
    text = text.strip()
    match = re.search(r"\[[\s\S]*\]", text)
    if not match:
        return []
    try:
        value = json.loads(match.group(0))
        return value if isinstance(value, list) else []
    except Exception:
        return []


def parse_qwen_tool_calls(text):
    calls = []
    for block in re.findall(r"<tool_call>\s*(.*?)\s*</tool_call>", text, flags=re.S):
        fn = re.search(r"<function=([^>]+)>\s*(.*?)\s*</function>", block, flags=re.S)
        if not fn:
            continue
        name = fn.group(1).strip()
        body = fn.group(2)
        params = {}
        for key, value in re.findall(r"<parameter=([^>]+)>\s*(.*?)\s*</parameter>", body, flags=re.S):
            raw = value.strip()
            if key.strip() == "nearness":
                try:
                    params[key.strip()] = max(0.0, min(1.0, float(raw)))
                except ValueError:
                    params[key.strip()] = 0.7
            else:
                params[key.strip()] = raw.strip("\"'")
        if name in {"addBubble", "removeBubble"}:
            calls.append({"tool": name, "params": params})
    return calls


def normalize_tool_calls(calls, transcript):
    normalized = []
    for call in calls:
        if not isinstance(call, dict):
            continue
        tool = call.get("tool")
        params = call.get("params") if isinstance(call.get("params"), dict) else {}
        text = str(params.get("text", "")).strip()
        if tool == "addBubble" and text:
            try:
                nearness = float(params.get("nearness", 0.75))
            except Exception:
                nearness = 0.75
            normalized.append({
                "tool": "addBubble",
                "params": {"text": text, "nearness": max(0.0, min(1.0, nearness))},
            })
        elif tool == "removeBubble" and text:
            normalized.append({"tool": "removeBubble", "params": {"text": text}})
    return normalized or fallback_tools(transcript)


def fallback_tools(transcript):
    t = transcript.lower()
    tools = []
    wants_add = any(w in t for w in ["add", "more", "with", "bring in", "put in", "include", "give me"])
    wants_remove = any(w in t for w in ["remove", "less", "no ", "without", "take out", "drop"])
    if "lo-fi" in t or "lofi" in t or "lo fi" in t:
        tools.append({"tool": "addBubble", "params": {"text": "lo-fi dusty warm beats", "nearness": 0.85}})
    if "jazz" in t:
        tools.append({"tool": "addBubble", "params": {"text": "jazz harmony", "nearness": 0.75}})
    instruments = [
        ("drum", "drums"),
        ("sax", "saxophone"),
        ("guitar", "guitar"),
        ("piano", "piano"),
        ("keyboard", "keyboard"),
        ("trumpet", "trumpet"),
        ("trombone", "trombone"),
        ("violin", "violin"),
        ("banjo", "banjo"),
        ("flute", "flute"),
        ("harp", "harp"),
        ("maracas", "maracas"),
        ("accordion", "accordion"),
    ]
    for needle, prompt in instruments:
        if needle not in t:
            continue
        if wants_remove:
            tools.append({"tool": "removeBubble", "params": {"text": prompt}})
        elif wants_add:
            tools.append({"tool": "addBubble", "params": {"text": prompt, "nearness": 0.85}})
    if not tools and transcript.strip():
        tools.append({"tool": "addBubble", "params": {"text": transcript.strip(), "nearness": 0.7}})
    return tools


class QwenAgent:
    def __init__(self):
        self.model = None
        self.tokenizer = None

    def load(self):
        if self.model is not None:
            return
        from mlx_lm.utils import load_model, load_tokenizer

        model_path = Path(snapshot_download("mlx-community/Qwen3.5-4B-MLX-4bit", local_files_only=True))
        self.model, _ = load_model(model_path, strict=False)
        self.tokenizer = load_tokenizer(model_path)
        emit({"event": "agent_loaded", "model": str(model_path)})

    def decide(self, transcript):
        self.load()
        from mlx_lm import generate

        tools_schema = [
            {
                "type": "function",
                "function": {
                    "name": "addBubble",
                    "description": "Add a bubble to influence the generated music.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": {
                                "type": "string",
                                "description": "A short musical prompt such as drums, lo-fi, saxophone, warmer bass, or faster jazz.",
                            },
                            "nearness": {
                                "type": "number",
                                "description": "Influence strength from 0.0 to 1.0. Use 0.85 for direct requests.",
                            },
                        },
                        "required": ["text", "nearness"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "removeBubble",
                    "description": "Remove an existing music bubble that matches the requested text.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": {
                                "type": "string",
                                "description": "The musical prompt/instrument/style to remove.",
                            }
                        },
                        "required": ["text"],
                    },
                },
            },
        ]
        system = (
            "You control a musical bubble UI for a live music generator. "
            "Always call a tool when the user asks to add, remove, reduce, or change an instrument/style/mood. "
            "Use addBubble for requested additions or transformations. "
            "Use removeBubble for remove/reduce/less/no/without requests. "
            "Keep tool text short and musical, not conversational."
        )
        user = f"User said: {transcript!r}"
        messages = [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ]
        if hasattr(self.tokenizer, "apply_chat_template"):
            prompt = self.tokenizer.apply_chat_template(
                messages,
                tools=tools_schema,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        else:
            prompt = f"{system}\n\n{user}\nJSON:"
        response = generate(
            self.model,
            self.tokenizer,
            prompt,
            verbose=False,
            max_tokens=256,
        )
        tools = parse_qwen_tool_calls(response) or extract_json_array(response)
        return normalize_tool_calls(tools, transcript), response


class WhisperAgent:
    def __init__(self):
        self.path = snapshot_download("mlx-community/whisper-base.en-mlx", local_files_only=True)

    def transcribe(self, pcm):
        import mlx_whisper

        audio = pcm_to_float32(pcm)
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.path,
            verbose=False,
            language="en",
            condition_on_previous_text=False,
            no_speech_threshold=0.55,
        )
        return (result.get("text") or "").strip()


def main():
    emit({"event": "ready"})
    whisper = WhisperAgent()
    qwen = QwenAgent()

    active = False
    speech = bytearray()
    silence_bytes = 0
    speech_started_at = 0.0

    while True:
        chunk = sys.stdin.buffer.read(CHUNK_BYTES)
        if not chunk:
            time.sleep(0.01)
            continue

        level = rms_i16(chunk)
        if not active:
            if level >= START_RMS:
                active = True
                speech = bytearray(chunk)
                silence_bytes = 0
                speech_started_at = time.time()
                emit({"event": "speech_started"})
            continue

        speech.extend(chunk)
        if level < END_RMS:
            silence_bytes += len(chunk)
        else:
            silence_bytes = 0

        speech_sec = len(speech) / (SAMPLE_RATE * SAMPLE_WIDTH)
        silence_sec = silence_bytes / (SAMPLE_RATE * SAMPLE_WIDTH)
        should_finish = (
            (speech_sec >= MIN_SPEECH_SEC and silence_sec >= END_SILENCE_SEC)
            or speech_sec >= MAX_SPEECH_SEC
        )
        if not should_finish:
            continue

        pcm = bytes(speech)
        active = False
        speech = bytearray()
        silence_bytes = 0
        emit({"event": "committed"})

        transcript = ""
        try:
            transcript = whisper.transcribe(pcm)
            if not transcript:
                emit({"event": "result", "transcript": "", "tools": []})
                continue
            emit({"event": "transcribed", "transcript": transcript})
            tools, raw = qwen.decide(transcript)
            emit({"event": "result", "transcript": transcript, "tools": tools, "raw": raw})
        except Exception as exc:
            emit({"event": "error", "message": repr(exc), "transcript": transcript, "tools": fallback_tools(transcript)})


if __name__ == "__main__":
    main()
