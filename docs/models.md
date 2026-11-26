# Model comparison

Sizes are the Ollama Q4 downloads (`ollama.com/library`, checked 2026-11-26). RAM figures are the container
`MEM_LIMIT` the model needs for the default `OLLAMA_CONTEXT_LENGTH=8192`; everything here runs on CPU, so speed
is relative, not measured.

| `MODEL_FAMILY` / `MODEL_PROFILE` | Ollama tag | Disk | Container RAM | Relative speed |
|---|---|---|---|---|
| `qwen` / `8gb` (default) | `qwen2.5-coder:7b` | 4.7 GB | 8 GB | medium |
| `qwen` / `16gb` | `qwen2.5-coder:14b` | 9.0 GB | 16 GB | slow |
| `gemma` / `8gb` | `gemma3:4b` | 3.4 GB | 8 GB | fastest |
| `gemma` / `16gb` | `gemma3:12b` | 8.2 GB | 16 GB | slow |
| `devstral` / `16gb` | `devstral-small-2:24b` | 15 GB | 16 GB is the floor; see below | slowest |
| `devstral` / `8gb` | not available: the smallest Devstral is 24B (14–15 GB). The build fails with a message. | | | |

## Qwen2.5-Coder (Alibaba, Apache 2.0)

**Best for:** the rules-based review and the pre-commit `agent-review`. The default.

- Pros: trained on code, so it follows "rewrite this file to satisfy these rules" instructions tightly and
  keeps the rest of the file untouched. Best code quality per GB of the three: the 7B fits an 8 GB container
  with room for context. Permissive license. 32k native context.
- Cons: English explanations and docstrings are terser and more mechanical than Gemma's. Code-only: no vision,
  no general knowledge to speak of. The 2024 training cut-off shows on newer library APIs.
- Resources: 7B ≈ 5 GB resident plus ~1 GB of context cache; 14B ≈ 10 GB plus cache.

## Gemma 3 (Google, Gemma Terms of Use)

**Best for:** the *General CR* button: comments, docstrings and plain-English review notes, and the only
family that is comfortable in 8 GB with the fastest turnaround.

- Pros: general-purpose model with the most natural prose, so "explain why" comments and docstrings read
  well. 128k context. The 4B is small and fast; the 12B is a solid all-rounder in 16 GB.
- Cons: not a code-specialist: at equal size it makes more logic slips than Qwen-Coder and drifts further
  from "change nothing else" instructions, so review the diff more carefully. The license is permissive but
  not OSI-approved and carries use restrictions. Multimodal weights are dead weight here.
- Resources: 4B ≈ 4 GB resident; 12B ≈ 9 GB resident, both plus context cache.

## Devstral Small 2 (Mistral AI, Apache 2.0)

**Best for:** the deepest review when you have 16 GB or more and can wait: multi-concern refactors,
spotting real bugs, reasoning across a larger file.

- Pros: a 24B dense model built for software-engineering agents (Mistral reports it as the strongest
  open-weight model of its size on SWE-bench Verified). Follows long, multi-part instructions best of the
  three. Long context. Permissive license.
- Cons: 15 GB on disk at Q4 and nothing smaller exists, so **16 GB is the floor, not a comfortable fit**:
  weights plus the 8k context cache plus the runtime exceed 16 GB and the kernel will page the weights.
  Give it `MEM_LIMIT=20g`, or keep 16 GB and set `OLLAMA_CONTEXT_LENGTH=4096` (a rewrite of a 150-line file
  will not fit twice in 4k tokens). On CPU it is several times slower than the 7B: a full-file rewrite can
  take 10+ minutes. Not tested in this repo.
- Resources: ≈ 15 GB resident plus ~1.3 GB per 8k of context.

## Which one

- 8 GB: `qwen` for both buttons. Switch to `gemma` only if you mainly use *General CR* for documentation.
- 16 GB: `qwen` (14B) for rules, `gemma` (12B) if prose matters more, `devstral` if you have RAM to spare and
  patience.
- The model is baked into the image, so switching families means a rebuild and a second image on disk.
