#!/usr/bin/env python3
"""
Export Whisper models using OpenVINO's native conversion (compatible with openvino-genai)
This should create models in the same format as your working whisper-base-npu
"""

import sys
from pathlib import Path
from optimum.exporters.openvino import main_export

def export_whisper_for_genai(model_size="small"):
    """Export Whisper using optimum with compat settings for openvino-genai"""

    model_map = {
        "base": "openai/whisper-base",
        "small": "openai/whisper-small",
        "medium": "openai/whisper-medium",
        "large-v3-turbo": "openai/whisper-large-v3-turbo",
    }

    if model_size not in model_map:
        print(f"Error: Invalid model size '{model_size}'")
        print(f"Valid options: {', '.join(model_map.keys())}")
        sys.exit(1)

    hf_model = model_map[model_size]
    output_dir = f"whisper-{model_size}-npu"

    print(f"Exporting {hf_model} for NPU (openvino-genai compatible)...")
    print(f"Output: {output_dir}")
    print()

    try:
        # Use optimum's main_export with explicit task
        # This creates models compatible with openvino-genai WhisperPipeline
        main_export(
            model_name_or_path=hf_model,
            output=output_dir,
            task="automatic-speech-recognition",
            framework="pt",  # PyTorch
            cache_dir=None,
            trust_remote_code=False,
        )

        print()
        print(f"✓ Export successful!")
        print(f"✓ Model saved to: {output_dir}")
        print()
        print("To use this model:")
        print("1. Open settings with Ctrl+Alt+Space")
        print(f"2. Select '{output_dir}' from Transcription Model dropdown")
        print("3. Select 'NPU' from Device dropdown")
        print("4. Click Save")

    except Exception as e:
        print(f"✗ Export failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    model_size = sys.argv[1] if len(sys.argv) > 1 else "small"
    export_whisper_for_genai(model_size)
