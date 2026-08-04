# LM Studio settings (set once in the GUI)

These cannot all be set from `lms`; configure them as the model's
**per-model defaults** (My Models → gear icon → Inference) so every
client request inherits them.

## Inference (anti-stall starting points — tune from here)
| Setting | Value | Why |
|---------|-------|-----|
| Temperature | 0.7 | Enough variance to escape action loops |
| Min-P | 0.05 | Cuts the degenerate tail without killing diversity |
| Repeat penalty | 1.05 | Mild — discourages literal action repetition |
| Context length | 65536 | Hermes requires at least 64k; agent loops need the room anyway |

## App settings
| Setting | Value | Why |
|---------|-------|-----|
| KV cache quantization | **8-bit (on)** | The old "off" rule was mlx-vlm-only — that runtime rejected KV quant on its batched vision path. We now run the GGUF/llama.cpp build (see `setup/02-model.sh`), which supports it. Worth having back: screenshot-driven agent loops fill 64k fast. |
| Context overflow | Truncate middle | Keeps system prompt + recent turns; prevents silent context-death stalls |
| Keep model loaded | On | Avoids reload latency between tasks |

> **Per-model settings do not follow across formats.** They attach to the
> format on disk, so the GGUF entry starts at LM Studio's stock defaults even
> if you tuned the MLX copy. Re-apply the Inference table above on the GGUF
> entry.

## Vision (required for computer use)
Confirm the model shows a **Vision** badge under My Models. llama.cpp only
accepts image input when a multimodal projector (`mmproj`) is paired with the
weights; if LM Studio didn't pair one, the badge is absent and computer use
silently degrades to accessibility-tree-only. `setup/03-verify.sh` probes this
directly with a 1x1 PNG — trust the probe over the badge.

Fallback if LM Studio won't pair an mmproj:

    llama-server -m <model>.gguf --mmproj <mmproj>.gguf --jinja -c 65536

`--jinja` is required in either path; without it the Qwen3.6 chat template
isn't applied and the model emits malformed turns.

## Verification
`setup/03-verify.sh` exercises the endpoint including a tool-call
round-trip. If tool calls come back malformed, check that the model's
prompt template in LM Studio is the built-in Qwen3.6 template, not a
generic fallback.
