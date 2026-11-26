# Model comparison

Sizes are the Ollama Q4 downloads (`ollama.com/library`, checked 2026-11-26). "Container RAM" is the
`MEM_LIMIT` the model needs at the default `OLLAMA_CONTEXT_LENGTH=8192`; `./up.sh` sets it from the profile.
Everything runs on CPU, so speed is relative, not measured.

| `OLLAMA_MODEL` | `MODEL_FAMILY` / `MODEL_PROFILE` | Disk | Container RAM | Relative speed |
|---|---|---|---|---|
| `qwen2.5-coder:7b` (default) | `qwen` / `8gb` | 4.7 GB | 8 GB | medium |
| `qwen2.5-coder:14b` | `qwen` / `16gb` | 9.0 GB | 16 GB | slow |
| `gemma4:e2b` | `gemma` / `8gb` | 4.6 GB | 8 GB | fastest |
| `gemma4:12b` | `gemma` / `16gb` | 7.7 GB | 16 GB | slow |
| `devstral-small-2:24b` | `devstral` / `16gb` | 15 GB | 16 GB is the floor; see below | slowest |
| `devstral` / `8gb` | not available: the smallest Devstral is 24B (14–15 GB). The build fails with a message. | | | |

Any other tag works with `OLLAMA_MODEL=<tag> MEM_LIMIT=<n>g ./up.sh`; the rows above are only the defaults.

## The use cases

- **Rule-based review**: rewrite a file (or review a staged diff) so it satisfies `.agent/rules.md` and the
  patterns in past PR comments, changing nothing else. Needs a model that follows constraints tightly and
  keeps its hands off the rest of the file.
- **General review**: clarity, organization, comments that explain *why*, docstrings for public functions
  and classes, without changing behavior. Needs good prose as much as good code.
- **Pre-commit findings**: a short list of `file:line – rule – fix` for the staged diff. Needs precision
  over fluency, and must say "No findings" rather than invent issues.

## Qwen2.5-Coder (Alibaba, Apache 2.0)

**Best for:** rule-based review and pre-commit findings. The default.

- Pros: trained on code, so it follows "rewrite this file to satisfy these rules" tightly and leaves the
  rest untouched; the fewest invented findings of the three. Best code quality per GB: the 7B fits an 8 GB
  container with room for context. Permissive license. 32k native context.
- Cons: explanations and docstrings are terser and more mechanical than Gemma's, so general review reads
  flatter. Code-only: no general knowledge to speak of. The 2024 training cut-off shows on newer library
  APIs.
- Resources: 7B ≈ 5 GB resident plus ~1 GB of context cache; 14B ≈ 10 GB plus cache.

## Gemma 4 (Google, Apache 2.0)

**Best for:** general review (comments, docstrings, plain-English notes), and the fastest turnaround in
8 GB.

- Pros: general-purpose model with the most natural prose, so "explain why" comments and docstrings read
  well. Long context (128k for the small sizes, 256k for 12B+). Apache 2.0, unlike Gemma 3's custom
  terms. The 12B is a solid all-rounder in 16 GB.
- Cons: not a code specialist: at equal size it makes more logic slips than Qwen-Coder and drifts further
  from "change nothing else", so read rule-based diffs more carefully. The `e2b` default for 8 GB is small
  (effective 2B); `gemma4:e4b` (6.6 GB) is noticeably better but needs about 10 GB:
  `OLLAMA_MODEL=gemma4:e4b MEM_LIMIT=10g ./up.sh`. Multimodal weights are dead weight here.
- Resources: e2b ≈ 5 GB resident; 12B ≈ 8.5 GB resident, both plus context cache.

## Devstral Small 2 (Mistral AI, Apache 2.0)

**Best for:** the deepest rule-based review when you have 16 GB or more and can wait: multi-concern
refactors, real bugs, reasoning across a larger file.

- Pros: a 24B dense model built for software-engineering agents (Mistral reports it as the strongest
  open-weight model of its size on SWE-bench Verified). Follows long, multi-part rule lists best of the
  three. Long context. Permissive license.
- Cons: 15 GB on disk at Q4 and nothing smaller exists, so **16 GB is the floor, not a comfortable fit**:
  weights plus the 8k context cache plus the runtime exceed 16 GB and the kernel will page the weights.
  Give it `MEM_LIMIT=20g` (`./up.sh` defaults to 16g for this profile), or keep 16 GB and set
  `OLLAMA_CONTEXT_LENGTH=4096` (a rewrite of a 150-line file will not fit twice in 4k tokens). On CPU it
  is several times slower than the 7B: a full-file rewrite can take 10+ minutes. Not tested in this repo.
- Resources: ≈ 15 GB resident plus ~1.3 GB per 8k of context.

## Which one

- 8 GB: `qwen` for everything. Switch to `gemma` only if general review (documentation) is most of your use.
- 16 GB: `qwen` (14B) for rule-based review, `gemma` (12B) if prose matters more, `devstral` if you have
  RAM to spare and patience.
- The model is baked into the image, so switching means a rebuild and a second image on disk.
