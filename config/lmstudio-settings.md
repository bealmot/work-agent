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
| KV cache quantization | 8-bit | ~halves KV memory — load-bearing at 64k context; negligible quality loss |
| Context overflow | Truncate middle | Keeps system prompt + recent turns; prevents silent context-death stalls |
| Keep model loaded | On | Avoids reload latency between tasks |

## Verification
`setup/03-verify.sh` exercises the endpoint including a tool-call
round-trip. If tool calls come back malformed, check that the model's
prompt template in LM Studio is the built-in Qwen3.6 template, not a
generic fallback.
