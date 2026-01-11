import sys
import argparse
import warnings
import openvino_genai as ov_genai
import soundfile as sf
import numpy as np

def read_audio(filepath):
    data, samplerate = sf.read(filepath)
    if samplerate != 16000:
        ratio = 16000 / samplerate
        new_length = int(len(data) * ratio)
        data = np.interp(np.linspace(0, len(data), new_length), np.arange(len(data)), data)
    return data.tolist()

parser = argparse.ArgumentParser()
parser.add_argument("audio_file", help="Path to audio file")
parser.add_argument("--cpu", action="store_true", help="Force CPU instead of NPU")
args = parser.parse_args()

# Suppress deprecation warnings
warnings.filterwarnings('ignore', message='Whisper decoder models with past is deprecated')

# Select device and corresponding model path
if args.cpu:
    device = "CPU"
    model_path = "./whisper-base-cpu"
else:
    device = "NPU"
    model_path = "./whisper-base-npu"

# Load pipeline
pipe = ov_genai.WhisperPipeline(model_path, device)

# Generate transcription
result = pipe.generate(read_audio(args.audio_file), max_new_tokens=100)
print(result)
