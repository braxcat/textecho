#!/bin/bash
# Install LLM backend options for dictation app
# Uses UV for package management

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "LLM Backend Installation Script"
echo "=========================================="
echo ""
echo "This script will install different LLM backends."
echo "You can then switch between them in the settings panel."
echo ""

show_menu() {
    echo "Select backends to install:"
    echo ""
    echo "  1) llama-cpp-python (CPU) - Basic CPU inference [INSTALLED]"
    echo "  2) llama-cpp-python (OpenVINO) - Optimized for Intel CPU"
    echo "  3) llama-cpp-python (SYCL/iGPU) - Use Intel integrated GPU"
    echo "  4) IPEX-LLM - Intel's LLM acceleration (CPU/iGPU/NPU)"
    echo "  5) OpenVINO GenAI - Native OpenVINO inference"
    echo "  6) Install ALL backends"
    echo "  7) Download recommended models"
    echo "  0) Exit"
    echo ""
}

install_cpu() {
    echo "Installing llama-cpp-python (CPU optimized)..."
    uv pip uninstall llama-cpp-python 2>/dev/null || true
    CMAKE_ARGS="-DLLAMA_AVX2=ON -DLLAMA_F16C=ON -DLLAMA_FMA=ON" uv pip install llama-cpp-python --force-reinstall
    echo "Done!"
}

install_openvino() {
    echo "Installing llama-cpp-python with OpenVINO backend..."
    uv pip uninstall llama-cpp-python 2>/dev/null || true
    CMAKE_ARGS="-DLLAMA_OPENVINO=ON" uv pip install llama-cpp-python --force-reinstall
    echo "Done!"
}

install_sycl() {
    echo "Installing llama-cpp-python with SYCL (Intel iGPU)..."
    echo "Note: Requires Intel oneAPI toolkit to be installed"
    echo ""

    # Check for oneAPI
    if [ ! -f "/opt/intel/oneapi/setvars.sh" ]; then
        echo "WARNING: Intel oneAPI not found at /opt/intel/oneapi/"
        echo "Install it first: https://www.intel.com/content/www/us/en/developer/tools/oneapi/toolkits.html"
        echo ""
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    else
        source /opt/intel/oneapi/setvars.sh
    fi

    uv pip uninstall llama-cpp-python 2>/dev/null || true
    CMAKE_ARGS="-DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx" uv pip install llama-cpp-python --force-reinstall
    echo "Done!"
}

install_ipex() {
    echo "Installing IPEX-LLM..."
    uv pip install ipex-llm[cpp]
    echo ""
    echo "IPEX-LLM installed. To use with llama.cpp:"
    echo "  - For CPU: Use ipex-llm's llama-cpp integration"
    echo "  - For iGPU: Set SYCL_CACHE_PERSISTENT=1"
    echo "  - For NPU: Additional setup required"
    echo "Done!"
}

install_openvino_genai() {
    echo "Installing OpenVINO GenAI..."
    echo "Note: This is for native OpenVINO models (not GGUF). Requires model conversion."
    echo ""
    # Install core packages only - avoid problematic optimum extras
    uv pip install openvino openvino-genai
    echo ""
    echo "OpenVINO GenAI installed."
    echo ""
    echo "NOTE: This requires converting models to OpenVINO format."
    echo "For GGUF models with our daemon, use option 2 (OpenVINO backend) instead."
    echo ""
    echo "To convert a model (requires optimum-cli):"
    echo "  pip install optimum-intel"
    echo "  optimum-cli export openvino --model meta-llama/Llama-3.2-3B-Instruct --weight-format int4 ./llama-3.2-3b-openvino"
    echo "Done!"
}

download_models() {
    echo "Downloading models..."
    echo ""

    MODELS_DIR="$SCRIPT_DIR/models"
    mkdir -p "$MODELS_DIR"

    echo "Select model to download (organized by size/speed):"
    echo ""
    echo "  === TINY (Ultra Fast, Basic Quality) ==="
    echo "  1) Gemma 3 1B Instruct QAT Q4 (500MB) - Google's best tiny model"
    echo "  2) Qwen2.5 0.5B Instruct Q8_0 (530MB) - Blazing fast, simple tasks"
    echo ""
    echo "  === SMALL (Fast, Good Quality) ==="
    echo "  3) Qwen2.5 1.5B Instruct Q4_K_M (1.0GB) - Great speed/quality balance"
    echo "  4) DeepSeek-R1-Distill-Qwen-1.5B Q4_K_M (1.1GB) - Fast with reasoning"
    echo "  5) Gemma 2 2B Instruct Q4_K_M (1.5GB) - Google, punches above weight"
    echo "  6) Llama 3.2 1B Instruct Q4_K_M (0.8GB) - Fast, decent quality"
    echo ""
    echo "  === MEDIUM (Balanced) ==="
    echo "  7) Gemma 3 4B Instruct QAT Q4 (2.6GB) - Google's best, 128K context"
    echo "  8) Qwen2.5 3B Instruct Q4_K_M (2.0GB) - Excellent quality"
    echo "  9) Llama 3.2 3B Instruct Q4_K_M (2.0GB) - Great all-rounder"
    echo "  10) Phi-3.5 Mini 3.8B Q4_K_M (2.2GB) - Strong reasoning"
    echo ""
    echo "  === LARGE (Slower, Best Quality) ==="
    echo "  11) Llama 3.2 3B Instruct Q8_0 (3.2GB) - High quality"
    echo "  12) Qwen2.5 7B Instruct Q4_K_M (4.4GB) - Excellent (needs RAM)"
    echo ""
    echo "  0) Back"
    echo ""
    read -p "Choice: " model_choice

    case $model_choice in
        1)
            echo "Downloading Gemma 3 1B Instruct QAT Q4..."
            wget -c -O "$MODELS_DIR/gemma-3-1b-it-q4_0.gguf" \
                "https://huggingface.co/google/gemma-3-1b-it-qat-q4_0-gguf/resolve/main/gemma-3-1b-it-q4_0.gguf"
            echo "Downloaded to: $MODELS_DIR/gemma-3-1b-it-q4_0.gguf"
            ;;
        2)
            echo "Downloading Qwen2.5 0.5B Q8_0..."
            wget -c -O "$MODELS_DIR/Qwen2.5-0.5B-Instruct-Q8_0.gguf" \
                "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q8_0.gguf"
            echo "Downloaded to: $MODELS_DIR/Qwen2.5-0.5B-Instruct-Q8_0.gguf"
            ;;
        3)
            echo "Downloading Qwen2.5 1.5B Q4_K_M..."
            wget -c -O "$MODELS_DIR/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
            echo "Downloaded to: $MODELS_DIR/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
            ;;
        4)
            echo "Downloading DeepSeek-R1-Distill-Qwen-1.5B Q4_K_M..."
            wget -c -O "$MODELS_DIR/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf" \
                "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
            echo "Downloaded to: $MODELS_DIR/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
            ;;
        5)
            echo "Downloading Gemma 2 2B Instruct Q4_K_M..."
            wget -c -O "$MODELS_DIR/gemma-2-2b-it-Q4_K_M.gguf" \
                "https://huggingface.co/bartowski/gemma-2-2b-it-GGUF/resolve/main/gemma-2-2b-it-Q4_K_M.gguf"
            echo "Downloaded to: $MODELS_DIR/gemma-2-2b-it-Q4_K_M.gguf"
            ;;
        6)
            echo "Downloading Llama 3.2 1B Q4_K_M..."
            wget -c -O "$MODELS_DIR/Llama-3.2-1B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
            echo "Downloaded to: $MODELS_DIR/Llama-3.2-1B-Instruct-Q4_K_M.gguf"
            ;;
        7)
            echo "Downloading Gemma 3 4B Instruct QAT Q4..."
            wget -c -O "$MODELS_DIR/gemma-3-4b-it-q4_0.gguf" \
                "https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-gguf/resolve/main/gemma-3-4b-it-q4_0.gguf"
            echo "Downloaded to: $MODELS_DIR/gemma-3-4b-it-q4_0.gguf"
            ;;
        8)
            echo "Downloading Qwen2.5 3B Q4_K_M..."
            wget -c -O "$MODELS_DIR/Qwen2.5-3B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
            echo "Downloaded to: $MODELS_DIR/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
            ;;
        9)
            echo "Downloading Llama 3.2 3B Q4_K_M..."
            wget -c -O "$MODELS_DIR/Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
            echo "Downloaded to: $MODELS_DIR/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
            ;;
        10)
            echo "Downloading Phi-3.5 Mini Q4_K_M..."
            wget -c -O "$MODELS_DIR/Phi-3.5-mini-instruct-Q4_K_M.gguf" \
                "https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf"
            echo "Downloaded to: $MODELS_DIR/Phi-3.5-mini-instruct-Q4_K_M.gguf"
            ;;
        11)
            echo "Downloading Llama 3.2 3B Q8_0..."
            wget -c -O "$MODELS_DIR/Llama-3.2-3B-Instruct-Q8_0.gguf" \
                "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q8_0.gguf"
            echo "Downloaded to: $MODELS_DIR/Llama-3.2-3B-Instruct-Q8_0.gguf"
            ;;
        12)
            echo "Downloading Qwen2.5 7B Q4_K_M..."
            wget -c -O "$MODELS_DIR/Qwen2.5-7B-Instruct-Q4_K_M.gguf" \
                "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf"
            echo "Downloaded to: $MODELS_DIR/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
            ;;
        *)
            return
            ;;
    esac

    echo ""
    echo "Model downloaded! Use Ctrl+Alt+Space to open settings and select it."
}

# Main loop
while true; do
    show_menu
    read -p "Choice: " choice
    echo ""

    case $choice in
        1)
            install_cpu
            ;;
        2)
            install_openvino
            ;;
        3)
            install_sycl
            ;;
        4)
            install_ipex
            ;;
        5)
            install_openvino_genai
            ;;
        6)
            echo "Installing all backends..."
            install_cpu
            install_ipex
            install_openvino_genai
            echo ""
            echo "Note: llama-cpp-python can only have one backend at a time."
            echo "The last installed (CPU) is active. Use settings to switch."
            ;;
        7)
            download_models
            ;;
        0)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac

    echo ""
    echo "=========================================="
    echo ""
done
