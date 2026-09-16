#!/usr/bin/env bash
# Downloads one SVG per catalogue provider into the ProviderLogos asset catalogue.
#
# Sources, tried in order for each id:
#   1. lobe-icons (MIT)   https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg
#   2. simple-icons (CC0) https://cdn.jsdelivr.net/npm/simple-icons
# An id that neither source has is left without an imageset: LogoTile draws an SF Symbol
# instead. `custom` is always an SF Symbol, so it is never fetched.
#
# Two ids are never fetched: `gemini` and `gemini-cli` are PNGs. Their artwork is a gradient,
# and Xcode's asset catalogue renders no gradient in an SVG, so the SVG versions came out blank
# in the app; both imagesets hold light/dark PNGs instead. Re-running this script must not put
# the invisible SVGs back over them.
#
# Safe to re-run: each id's imageset is rewritten from scratch, and one that has stopped
# resolving is removed rather than left pointing at a stale file.
set -euo pipefail
cd "$(dirname "$0")/.."

out="Ties/Resources/Assets.xcassets/ProviderLogos"
lobe="https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg/icons"
simple="https://cdn.jsdelivr.net/npm/simple-icons@latest/icons"

# "<catalogue id> <icon name>". The simple-icons attempt reuses the same name with the
# lobe-icons `-color` suffix dropped, which is also its slug convention.
logos=(
  "apple apple"
  "gemini gemini-color"
  "groq groq"
  "openrouter openrouter"
  "claude-cli claude-color"
  "codex-cli openai"
  "gemini-cli gemini-color"
  "ollama ollama"
  "lmstudio lmstudio"
  "llamacpp llamacpp"
  "mlx apple"
  "jan jan"
  "gpt4all gpt4all"
  "openai openai"
  "anthropic anthropic"
  "perplexity perplexity-color"
  "xai xai"
  "mistral mistral-color"
  "deepseek deepseek-color"
  "cohere cohere-color"
  "fireworks fireworks-color"
  "together together-color"
  "cloudflare cloudflare-color"
  "huggingface huggingface-color"
  "sambanova sambanova-color"
)

# The ids whose imageset is a hand-made PNG pair; see the note at the top.
png_only=("gemini" "gemini-cli")

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fetches $1 into $2, keeping it only if the bytes really are an SVG document — a CDN that
# answers 200 with an HTML error page must not become someone's logo.
fetch_svg() {
  curl -fsSL --max-time 20 -o "$2" "$1" || return 1
  local head
  head="$(head -c 200 "$2" | tr -d '\r\n\t ' | head -c 5)"
  case "$head" in
    "<svg"*|"<?xml"*) return 0 ;;
    *) return 1 ;;
  esac
}

write_imageset() {
  local id="$1" src="$2" dir="$out/$1.imageset"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$src" "$dir/$id.svg"
  cat > "$dir/Contents.json" <<JSON
{"images":[{"filename":"$id.svg","idiom":"universal"}],"info":{"author":"xcode","version":1},"properties":{"preserves-vector-representation":true}}
JSON
}

mkdir -p "$out"
cat > "$out/Contents.json" <<'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON

fetched=()
fallback=()
kept=()

for entry in "${logos[@]}"; do
  id="${entry%% *}"
  icon="${entry##* }"
  case " ${png_only[*]} " in
    *" $id "*)
      kept+=("$id")
      continue
      ;;
  esac
  file="$tmp/$id.svg"
  if fetch_svg "$lobe/$icon.svg" "$file"; then
    write_imageset "$id" "$file"
    fetched+=("$id (lobe-icons: $icon)")
  elif fetch_svg "$simple/${icon%-color}.svg" "$file"; then
    write_imageset "$id" "$file"
    fetched+=("$id (simple-icons: ${icon%-color})")
  else
    rm -rf "$out/$id.imageset"
    fallback+=("$id")
  fi
done

# Never fetched: the catalogue's escape hatch has no brand to show.
rm -rf "$out/custom.imageset"
fallback+=("custom")

echo
echo "Fetched ${#fetched[@]}:"
for line in "${fetched[@]:-}"; do [ -n "$line" ] && echo "  $line"; done
echo "SF Symbol fallback ${#fallback[@]}:"
for line in "${fallback[@]:-}"; do [ -n "$line" ] && echo "  $line"; done
echo "Left alone (PNG imagesets) ${#kept[@]}:"
for line in "${kept[@]:-}"; do [ -n "$line" ] && echo "  $line"; done
