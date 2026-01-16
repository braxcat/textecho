#!/bin/bash
# Export quantized Whisper models for faster transcription
# Usage: ./export_quantized_whisper.sh [base|small|medium]

MODEL_SIZE="${1:-small}"
OUTPUT_DIR="whisper-${MODEL_SIZE}-cpu-int8"

echo "Exporting Whisper ${MODEL_SIZE} with INT8 quantization..."
echo "Output directory: ${OUTPUT_DIR}"
echo ""

# Check if optimum-intel is installed
if ! uv run python -c "import optimum.intel" 2>/dev/null; then
    echo "ERROR: optimum-intel not installed"
    echo "Install with: uv pip install optimum-intel nncf"
    exit 1
fi

# Export with INT8 quantization
uv run optimum-cli export openvino \
    --model "openai/whisper-${MODEL_SIZE}" \
    --task automatic-speech-recognition \
    --weight-format int8 \
    "${OUTPUT_DIR}"

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Export successful!"
    echo "✓ Model saved to: ${OUTPUT_DIR}"
    echo ""
    echo "To use this model:"
    echo "1. Open settings with Ctrl+Alt+Space"
    echo "2. Select '${OUTPUT_DIR}' from Transcription Model dropdown"
    echo "3. Click Save"
else
    echo ""
    echo "✗ Export failed"
    exit 1
fi
