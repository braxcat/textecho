#!/usr/bin/env python3
"""
Export Whisper models for NPU without stateful decoder
Uses optimum-intel Python API for more control
"""

import sys
from pathlib import Path
from optimum.intel import OVModelForSpeechSeq2Seq
from transformers import AutoProcessor

def export_whisper(model_size="small", output_dir=None):
    """Export Whisper model to OpenVINO format for NPU"""

    # Map model size to HuggingFace model
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
    if output_dir is None:
        output_dir = f"whisper-{model_size}-npu"

    print(f"Exporting {hf_model} to {output_dir}...")
    print("This may take several minutes...")
    print()

    try:
        # Export with use_cache=True to include beam_idx input
        # NPU requires beam_idx for stateful models (error without it)
        model = OVModelForSpeechSeq2Seq.from_pretrained(
            hf_model,
            export=True,
            use_cache=True,  # Key: enable cache to get beam_idx input that NPU needs
            compile=False,
        )

        # Save the exported model
        model.save_pretrained(output_dir)

        # Also save the processor/tokenizer
        processor = AutoProcessor.from_pretrained(hf_model)
        processor.save_pretrained(output_dir)

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
        sys.exit(1)

if __name__ == "__main__":
    model_size = sys.argv[1] if len(sys.argv) > 1 else "small"
    export_whisper(model_size)
