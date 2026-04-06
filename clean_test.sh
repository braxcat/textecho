#!/bin/bash
# clean_test.sh — Remove all TextEcho data for fresh first-launch testing.
# Run this before ./install_dev.sh to test the full setup wizard experience.
#
# Usage:
#   ./clean_test.sh          # Interactive — prompts before deleting
#   ./clean_test.sh --force  # No prompts — just delete everything

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

echo -e "${YELLOW}TextEcho Clean Test — removes all local data for fresh testing${NC}"
echo ""

# Paths to remove
CONFIG="$HOME/.textecho_config"
HISTORY="$HOME/.textecho_history.json"
REGISTERS="$HOME/.textecho_registers.json"
LOGS="$HOME/Library/Logs/TextEcho"
FLUID_MODELS="$HOME/Library/Application Support/FluidAudio"
WHISPER_MODELS="$HOME/Documents/huggingface/models/argmaxinc"
MLX_CACHE="$HOME/.cache/huggingface/hub"

MLX_MODELS="$MLX_CACHE/models--mlx-community--*"

items=(
    "$CONFIG|Config file"
    "$HISTORY|History file"
    "$REGISTERS|Registers file"
    "$LOGS|Log directory"
    "$FLUID_MODELS|Parakeet/FluidAudio models (~2GB)"
    "$WHISPER_MODELS|WhisperKit models (~1.6GB)"
)

echo "Will remove:"
for item in "${items[@]}"; do
    path="${item%%|*}"
    label="${item##*|}"
    if [[ -e "$path" ]]; then
        echo -e "  ${RED}✗${NC} $label — $path"
    else
        echo -e "  ${GREEN}✓${NC} $label — (not found, skipping)"
    fi
done

# Check MLX models separately (glob pattern)
mlx_count=$(ls -d $MLX_MODELS 2>/dev/null | wc -l | tr -d ' ')
if [[ "$mlx_count" -gt 0 ]]; then
    echo -e "  ${RED}✗${NC} MLX/LLM models ($mlx_count cached) — $MLX_CACHE/models--mlx-community--*"
else
    echo -e "  ${GREEN}✓${NC} MLX/LLM models — (not found, skipping)"
fi
echo ""

if [[ "$FORCE" != true ]]; then
    read -rp "Proceed? [y/N] " confirm
    [[ "$confirm" != [yY] ]] && echo "Cancelled." && exit 0
fi

# Kill TextEcho if running
if pgrep -x TextEcho > /dev/null 2>&1; then
    echo "Stopping TextEcho..."
    killall TextEcho 2>/dev/null || true
    sleep 1
fi

# Remove items
for item in "${items[@]}"; do
    path="${item%%|*}"
    label="${item##*|}"
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        echo -e "  ${RED}Removed${NC} $label"
    fi
done

# Remove MLX models
if ls -d $MLX_MODELS &>/dev/null; then
    rm -rf $MLX_MODELS
    echo -e "  ${RED}Removed${NC} MLX/LLM models"
fi

echo ""
echo -e "${GREEN}Clean! Ready for fresh test:${NC}"
echo "  ./install_dev.sh"
echo ""
echo "First launch will show the setup wizard with model download."
