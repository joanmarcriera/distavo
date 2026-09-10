#!/usr/bin/env bash
# Convert a Hugging Face Whisper checkpoint to WhisperKit Core ML and publish it to
# Marc's repo (spec §5.7). Usage:
#   tools/whisperkit-models/convert.sh BSC-LT/whisper-large-v3-LoS
# Needs: uv, ~10 GB free, HF_TOKEN in ~/.tokens (write scope). Never prints the token.
# Pin the converter with WHISPERKITTOOLS_COMMIT=<sha> for a reproducible build.
set -euo pipefail
model="${1:?hf model id, e.g. BSC-LT/whisper-large-v3-LoS}"
repo="Joanmarcriera/distavo-whisperkit-coreml"
tools_commit="${WHISPERKITTOOLS_COMMIT:-main}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$here/.work"; mkdir -p "$work"
eval "$(grep '^export HF_TOKEN=' ~/.tokens)"; export HF_TOKEN
[ -d "$work/venv" ] || uv venv --python 3.11 "$work/venv"
# shellcheck disable=SC1091
source "$work/venv/bin/activate"
uv pip install -q "git+https://github.com/argmaxinc/whisperkittools.git@${tools_commit}" huggingface_hub
# The target repo must exist before whisperkittools commits into it; public, per Marc's decision 2026-09-10.
python -c "from huggingface_hub import HfApi; HfApi().create_repo('$repo', repo_type='model', private=False, exist_ok=True)"
src_rev="$(python -c "from huggingface_hub import HfApi; print(HfApi().model_info('$model').sha)")"
out="$work/out"; mkdir -p "$out"
# BSC publishes .bin weights; transformers refuses torch.load below torch 2.6, and
# whisperkittools pins torch 2.5. So re-save the checkpoint as safetensors in a sibling
# venv with a newer torch, then hand the converter a LOCAL directory. The directory
# is addressed by the RELATIVE path "<org>/<name>" so the converter (which accepts a
# local dir and names its output `model_version.replace("/", "_")`) produces the
# same folder name a Hub id would.
wvenv="$work/weights-venv"
[ -d "$wvenv" ] || uv venv --python 3.11 "$wvenv"
uv pip install -q --python "$wvenv/bin/python" "torch>=2.6" "transformers>=4.53" safetensors huggingface_hub
local="$work/src/$model"
if [ ! -f "$local/model.safetensors" ] && [ ! -f "$local/model.safetensors.index.json" ]; then
  "$wvenv/bin/python" - <<PY
from transformers import WhisperForConditionalGeneration, WhisperProcessor
m = WhisperForConditionalGeneration.from_pretrained("$model", revision="$src_rev")
m.save_pretrained("$local", safe_serialization=True)
WhisperProcessor.from_pretrained("$model", revision="$src_rev").save_pretrained("$local")
print("saved safetensors to $local")
PY
fi
( cd "$work/src" && MODEL_REPO_ID="$repo" whisperkit-generate-model --model-version "$model" --output-dir "$out" --upload-results )
folder="$(echo "$model" | tr '/' '_')"
python "$here/manifest.py" "$out/$folder" "$model" "$src_rev" "$tools_commit" > "$out/$folder/manifest.json"
python - <<PY
from huggingface_hub import HfApi
HfApi().upload_file(path_or_fileobj="$out/$folder/manifest.json", path_in_repo="$folder/manifest.json", repo_id="$repo")
PY
echo "published $repo/$folder (source $src_rev)"
