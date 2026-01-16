#!/bin/bash
# Export Whisper models for Intel NPU
# Usage: ./export_whisper_npu.sh [base|small|medium|large-v3-turbo]

MODEL_SIZE="${1:-small}"
OUTPUT_DIR="whisper-${MODEL_SIZE}-npu"

echo "Exporting Whisper ${MODEL_SIZE} for Intel NPU..."
echo "Output directory: ${OUTPUT_DIR}"
echo ""

# Map model size to HuggingFace model name
case "$MODEL_SIZE" in
    "base")
        HF_MODEL="openai/whisper-base"
        ;;
    "small")
        HF_MODEL="openai/whisper-small"
        ;;
    "medium")
        HF_MODEL="openai/whisper-medium"
        ;;
    "large-v3-turbo")
        HF_MODEL="openai/whisper-large-v3-turbo"
        ;;
    *)
        echo "ERROR: Invalid model size. Use: base, small, medium, or large-v3-turbo"
        exit 1
        ;;
esac

echo "Downloading and converting ${HF_MODEL}..."
echo "This may take several minutes..."
echo ""

# For NPU, use these specific flags:
# - --task automatic-speech-recognition-with-past: includes KV cache decoder
# - --disable-stateful: required for NPU (stateful models don't work on NPU)
uv run optimum-cli export openvino \
    --model "${HF_MODEL}" \
    --task automatic-speech-recognition-with-past \
    --disable-stateful \
    "${OUTPUT_DIR}"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Export successful!"
    echo "✓ Model saved to: ${OUTPUT_DIR}"
    echo ""
    echo "To use this model:"
    echo "1. Open settings with Ctrl+Alt+Space"
    echo "2. Select '${OUTPUT_DIR}' from Transcription Model dropdown"
    echo "3. Select 'NPU' from Device dropdown"
    echo "4. Click Save"
else
    echo ""
    echo "✗ Export failed"
    exit 1
fi
