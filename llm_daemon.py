#!/usr/bin/env python3
"""
LLM Daemon - keeps model loaded, processes prompts via Unix socket.
Mirrors transcription_daemon.py architecture.

Dependencies (install manually):
    pip install llama-cpp-python

    # For Intel CPU optimization:
    CMAKE_ARGS="-DLLAMA_AVX2=ON -DLLAMA_F16C=ON" pip install llama-cpp-python

Model setup (download manually):
    # Phi-3 mini (recommended for speed)
    wget https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf

    # Or Llama 3.2 3B
    # Or any other GGUF model
"""

import json
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

# Configuration
SOCKET_PATH = "/tmp/dictation_llm.sock"
PID_FILE = os.path.expanduser("~/.dictation_llm.pid")
CONFIG_FILE = os.path.expanduser("~/.dictation_config")


class LLMDaemon:
    def __init__(self):
        self.model = None
        self.model_loaded = False
        self.last_request_time = None
        self.unload_timer = None
        self.lock = threading.Lock()

        # Load config
        self.config = self.load_config()
        self.idle_timeout = self.config.get("llm_idle_timeout", 1800)  # 30 min default
        self.model_path = self.config.get("llm_model_path", "")
        self.n_ctx = self.config.get(
            "llm_context_length", 131072
        )  # Llama 3.2's full 128K context
        self.n_threads = self.config.get(
            "llm_threads", 0
        )  # 0 = auto-detect (use all cores)
        self.default_system_prompt = self.config.get(
            "llm_system_prompt",
            "You are a helpful writing assistant. Respond concisely and directly with just the requested text. "
            "Do not include explanations, preambles, or meta-commentary. "
            "When context is provided (clipboard, registers), use it to inform your response but never mention or reference the register numbers, clipboard labels, or context structure in your output. "
            "Just provide the final text the user is asking for.",
        )
        self.default_max_tokens = self.config.get("llm_max_tokens", 512)
        self.default_temperature = self.config.get("llm_temperature", 0.7)
        self.repeat_penalty = self.config.get("llm_repeat_penalty", 1.1)  # Prevent repetitive output
        self.top_p = self.config.get("llm_top_p", 0.9)  # Nucleus sampling
        self.top_k = self.config.get("llm_top_k", 40)  # Top-k sampling
        self.debug_dump = self.config.get("llm_debug_dump", False)
        self.dump_file = os.path.expanduser("~/dictation/dictation_dump.txt")
        self.strip_reasoning = self.config.get("llm_strip_reasoning", True)  # Strip <think> tags by default
        self.prompt_format = self.config.get("llm_prompt_format", "auto")  # auto, phi, gemma, llama, chatml

        print("LLM daemon initialized")
        print(f"Model path: {self.model_path}")
        print(f"Context length: {self.n_ctx}")
        print(f"Threads: {self.n_threads}")
        print(f"Temperature: {self.default_temperature}")
        print(f"Repeat penalty: {self.repeat_penalty}")
        print(f"Top-p: {self.top_p}, Top-k: {self.top_k}")
        print(f"Strip reasoning: {self.strip_reasoning}")
        print(
            f"Idle timeout: {self.idle_timeout}s ({self.idle_timeout / 60:.1f} minutes)"
        )

    def load_config(self):
        """Load configuration from file."""
        if os.path.exists(CONFIG_FILE):
            try:
                with open(CONFIG_FILE, "r") as f:
                    config = json.load(f)
                    if isinstance(config, dict):
                        return config
            except Exception as e:
                print(f"Error loading config: {e}")
        return {}

    def load_model(self):
        """Load LLM model into memory (lazy loading)."""
        with self.lock:
            if self.model_loaded:
                return True

            if not self.model_path:
                print(
                    "ERROR: No model path configured. Set 'llm_model_path' in ~/.dictation_config"
                )
                return False

            if not os.path.exists(self.model_path):
                print(f"ERROR: Model file not found: {self.model_path}")
                return False

            print(f"Loading LLM model: {self.model_path}")
            start_time = time.time()

            try:
                from llama_cpp import Llama

                self.model = Llama(
                    model_path=self.model_path,
                    n_ctx=self.n_ctx,
                    n_threads=self.n_threads,
                    verbose=False,
                )
                self.model_loaded = True
                elapsed = time.time() - start_time
                print(f"Model loaded successfully in {elapsed:.2f}s")
                return True

            except ImportError:
                print("ERROR: llama-cpp-python not installed")
                print("Install with: pip install llama-cpp-python")
                print(
                    'For Intel optimization: CMAKE_ARGS="-DLLAMA_AVX2=ON" pip install llama-cpp-python'
                )
                return False

            except Exception as e:
                print(f"Error loading model: {e}")
                return False

    def unload_model(self):
        """Unload model from memory to free RAM."""
        with self.lock:
            if not self.model_loaded:
                return

            print("Unloading LLM model to free RAM...")
            self.model = None
            self.model_loaded = False

            # Force garbage collection
            import gc

            gc.collect()

            print("Model unloaded")

    def reset_unload_timer(self):
        """Reset the auto-unload timer."""
        if self.unload_timer:
            self.unload_timer.cancel()

        self.unload_timer = threading.Timer(self.idle_timeout, self.unload_model)
        self.unload_timer.daemon = True
        self.unload_timer.start()

    def _strip_reasoning(self, text):
        """Strip reasoning/thinking tags from model output."""
        import re
        # Remove <think>...</think> blocks
        text = re.sub(r'<think>.*?</think>', '', text, flags=re.DOTALL)
        # Remove <reasoning>...</reasoning> blocks
        text = re.sub(r'<reasoning>.*?</reasoning>', '', text, flags=re.DOTALL)
        # Remove any orphaned tags
        text = re.sub(r'</?think>', '', text)
        text = re.sub(r'</?reasoning>', '', text)
        return text.strip()

    def _detect_prompt_format(self):
        """Detect the appropriate prompt format from model name."""
        if self.prompt_format != "auto":
            return self.prompt_format

        model_lower = self.model_path.lower()
        if "gemma" in model_lower:
            return "gemma"
        elif "llama" in model_lower:
            return "llama"
        elif "phi" in model_lower:
            return "phi"
        elif "qwen" in model_lower:
            return "chatml"
        elif "deepseek" in model_lower:
            return "chatml"
        else:
            return "chatml"  # Default fallback

    def _build_prompt(self, prompt, context="", system_prompt=None):
        """Build the full prompt in the appropriate format for the model."""
        if system_prompt is None:
            system_prompt = self.default_system_prompt

        fmt = self._detect_prompt_format()
        print(f"Using prompt format: {fmt}")

        if fmt == "gemma":
            # Gemma format - no system role, include system instructions in user message
            if context:
                user_content = f"{system_prompt}\n\nContext:\n{context}\n\nRequest: {prompt}"
            else:
                user_content = f"{system_prompt}\n\n{prompt}"
            return f"<start_of_turn>user\n{user_content}<end_of_turn>\n<start_of_turn>model\n"

        elif fmt == "llama":
            # Llama 3 format
            if context:
                return f"""<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{system_prompt}<|eot_id|><|start_header_id|>user<|end_header_id|>

Context:
{context}

Request: {prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""
            else:
                return f"""<|begin_of_text|><|start_header_id|>system<|end_header_id|>

{system_prompt}<|eot_id|><|start_header_id|>user<|end_header_id|>

{prompt}<|eot_id|><|start_header_id|>assistant<|end_header_id|>

"""

        elif fmt == "phi":
            # Phi format
            if context:
                return f"""<|system|>
{system_prompt}<|end|>
<|user|>
Context:
{context}

Request: {prompt}<|end|>
<|assistant|>
"""
            else:
                return f"""<|system|>
{system_prompt}<|end|>
<|user|>
{prompt}<|end|>
<|assistant|>
"""

        else:  # chatml (default for Qwen, DeepSeek, etc.)
            if context:
                return f"""<|im_start|>system
{system_prompt}<|im_end|>
<|im_start|>user
Context:
{context}

Request: {prompt}<|im_end|>
<|im_start|>assistant
"""
            else:
                return f"""<|im_start|>system
{system_prompt}<|im_end|>
<|im_start|>user
{prompt}<|im_end|>
<|im_start|>assistant
"""

    def _get_stop_tokens(self):
        """Get appropriate stop tokens for the detected format."""
        fmt = self._detect_prompt_format()

        if fmt == "gemma":
            tokens = ["<end_of_turn>", "<start_of_turn>"]
        elif fmt == "llama":
            tokens = ["<|eot_id|>", "<|start_header_id|>"]
        elif fmt == "phi":
            tokens = ["<|end|>", "<|user|>", "<|system|>"]
        else:  # chatml
            tokens = ["<|im_end|>", "<|im_start|>"]

        # Add reasoning tokens if stripping enabled
        if self.strip_reasoning:
            tokens.extend(["<think>", "</think>", "<reasoning>", "</reasoning>"])

        return tokens

    def generate(
        self, prompt, context="", system_prompt=None, max_tokens=None, temperature=None
    ):
        """Generate a response from the LLM."""
        # Load model if needed
        if not self.model_loaded:
            if not self.load_model():
                return {"success": False, "error": "Failed to load model"}

        # Update request time and reset timer
        self.last_request_time = time.time()
        self.reset_unload_timer()

        # Use defaults if not specified
        if max_tokens is None:
            max_tokens = self.default_max_tokens
        if temperature is None:
            temperature = self.default_temperature

        # Build the full prompt using model-appropriate format
        full_prompt = self._build_prompt(prompt, context, system_prompt)
        stop_tokens = self._get_stop_tokens()

        # Debug dump if enabled
        if self.debug_dump:
            try:
                with open(self.dump_file, "w") as f:
                    f.write("=" * 60 + "\n")
                    f.write("LLM PROMPT DUMP\n")
                    f.write("=" * 60 + "\n\n")
                    f.write(f"System Prompt:\n{system_prompt}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"Context:\n{context if context else '(none)'}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"User Prompt:\n{prompt}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"Full Formatted Prompt:\n{full_prompt}\n")
                    f.write("=" * 60 + "\n")
                print(f"Prompt dumped to {self.dump_file}")
            except Exception as e:
                print(f"Error dumping prompt: {e}")

        try:
            with self.lock:
                print(f"Generating response for: {prompt[:50]}...")
                start_time = time.time()

                response = self.model(
                    full_prompt,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    stop=stop_tokens,
                    echo=False,
                    repeat_penalty=self.repeat_penalty,
                    top_p=self.top_p,
                    top_k=self.top_k,
                )

                elapsed = time.time() - start_time
                text = response["choices"][0]["text"].strip()

                # Strip any reasoning/thinking content that slipped through
                if self.strip_reasoning:
                    text = self._strip_reasoning(text)
                tokens = response.get("usage", {}).get("completion_tokens", 0)

                print(f"Generated {tokens} tokens in {elapsed:.2f}s")

                return {
                    "success": True,
                    "response": text,
                    "tokens": tokens,
                    "time": elapsed,
                }

        except Exception as e:
            print(f"Generation error: {e}")
            return {"success": False, "error": str(e)}

    def generate_stream(
        self,
        conn,
        prompt,
        context="",
        system_prompt=None,
        max_tokens=None,
        temperature=None,
    ):
        """Generate a streaming response from the LLM, sending tokens as they arrive."""
        # Load model if needed
        if not self.model_loaded:
            if not self.load_model():
                conn.sendall(
                    (json.dumps({"error": "Failed to load model"}) + "\n").encode()
                )
                return

        # Update request time and reset timer
        self.last_request_time = time.time()
        self.reset_unload_timer()

        # Use defaults if not specified
        if max_tokens is None:
            max_tokens = self.default_max_tokens
        if temperature is None:
            temperature = self.default_temperature

        # Build the full prompt using model-appropriate format
        full_prompt = self._build_prompt(prompt, context, system_prompt)
        stop_tokens = self._get_stop_tokens()

        # Debug dump if enabled
        if self.debug_dump:
            try:
                with open(self.dump_file, "w") as f:
                    f.write("=" * 60 + "\n")
                    f.write("LLM PROMPT DUMP (STREAMING)\n")
                    f.write("=" * 60 + "\n\n")
                    f.write(f"System Prompt:\n{system_prompt}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"Context:\n{context if context else '(none)'}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"User Prompt:\n{prompt}\n\n")
                    f.write("-" * 60 + "\n")
                    f.write(f"Full Formatted Prompt:\n{full_prompt}\n")
                    f.write("=" * 60 + "\n")
                print(f"Prompt dumped to {self.dump_file}")
            except Exception as e:
                print(f"Error dumping prompt: {e}")

        try:
            with self.lock:
                print(f"Streaming response for: {prompt[:50]}...")
                start_time = time.time()
                full_response = ""

                # Stream tokens
                for output in self.model(
                    full_prompt,
                    max_tokens=max_tokens,
                    temperature=temperature,
                    stop=stop_tokens,
                    echo=False,
                    stream=True,
                    repeat_penalty=self.repeat_penalty,
                    top_p=self.top_p,
                    top_k=self.top_k,
                ):
                    token = output["choices"][0]["text"]
                    full_response += token
                    # Send token to client
                    conn.sendall((json.dumps({"token": token}) + "\n").encode())

                elapsed = time.time() - start_time
                print(f"Streamed {len(full_response)} chars in {elapsed:.2f}s")

                # Strip any reasoning content from final response if enabled
                clean_response = self._strip_reasoning(full_response) if self.strip_reasoning else full_response.strip()

                # Send done signal
                conn.sendall(
                    (
                        json.dumps(
                            {"done": True, "full_response": clean_response}
                        )
                        + "\n"
                    ).encode()
                )

        except Exception as e:
            print(f"Streaming error: {e}")
            conn.sendall((json.dumps({"error": str(e)}) + "\n").encode())

    def handle_client(self, conn):
        """Handle client connection."""
        try:
            # Receive request
            data = b""
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                if b"\n" in chunk:
                    break

            if not data:
                return

            request = json.loads(data.decode())
            command = request.get("command")

            if command == "generate":
                prompt = request.get("prompt", "")
                context = request.get("context", "")
                system_prompt = request.get("system_prompt")
                max_tokens = request.get("max_tokens")
                temperature = request.get("temperature")

                result = self.generate(
                    prompt=prompt,
                    context=context,
                    system_prompt=system_prompt,
                    max_tokens=max_tokens,
                    temperature=temperature,
                )
                response = json.dumps(result) + "\n"
                conn.sendall(response.encode())

            elif command == "generate_stream":
                prompt = request.get("prompt", "")
                context = request.get("context", "")
                system_prompt = request.get("system_prompt")
                max_tokens = request.get("max_tokens")
                temperature = request.get("temperature")

                # Streaming doesn't close connection in finally - handled in generate_stream
                self.generate_stream(
                    conn=conn,
                    prompt=prompt,
                    context=context,
                    system_prompt=system_prompt,
                    max_tokens=max_tokens,
                    temperature=temperature,
                )
                return  # Don't close connection in finally, already handled

            elif command == "status":
                status = {
                    "model_loaded": self.model_loaded,
                    "model_path": self.model_path,
                    "last_request": self.last_request_time,
                    "idle_timeout": self.idle_timeout,
                }
                response = json.dumps(status) + "\n"
                conn.sendall(response.encode())

            elif command == "unload":
                self.unload_model()
                response = json.dumps({"success": True}) + "\n"
                conn.sendall(response.encode())

            elif command == "ping":
                response = json.dumps({"success": True, "pong": True}) + "\n"
                conn.sendall(response.encode())

        except Exception as e:
            print(f"Error handling client: {e}")
            try:
                error_response = json.dumps({"success": False, "error": str(e)}) + "\n"
                conn.sendall(error_response.encode())
            except:
                pass
        finally:
            conn.close()

    def warmup(self):
        """Warm up the model by loading it and running a short prompt."""
        print("Warming up LLM model...")

        if not self.load_model():
            print("Warmup failed: could not load model")
            return False

        # Run a short prompt to warm up the inference
        try:
            with self.lock:
                self.model(
                    "Hello",
                    max_tokens=1,
                    temperature=0.0,
                )
            print("Warmup complete - model ready")
            self.reset_unload_timer()
            return True
        except Exception as e:
            print(f"Warmup inference failed: {e}")
            return False

    def run(self):
        """Run the daemon server."""
        # Remove old socket if exists
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            if os.path.exists(SOCKET_PATH):
                raise

        # Create Unix domain socket
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(SOCKET_PATH)
        server.listen(5)

        # Write PID file
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

        print(f"LLM daemon listening on {SOCKET_PATH}")
        print(f"PID: {os.getpid()}")

        # Handle SIGTERM gracefully (launchd sends this on stop)
        import signal

        def _shutdown(signum, frame):
            print(f"\nReceived signal {signum}, shutting down...")
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, _shutdown)

        # Warm up model in background thread
        warmup_thread = threading.Thread(target=self.warmup, daemon=True)
        warmup_thread.start()

        # Use thread pool to limit concurrent connections
        executor = ThreadPoolExecutor(max_workers=2)

        try:
            while True:
                conn, _ = server.accept()
                executor.submit(self.handle_client, conn)
        except (KeyboardInterrupt, SystemExit):
            print("\nShutting down...")
        finally:
            # Cancel unload timer if running
            if self.unload_timer:
                self.unload_timer.cancel()
            executor.shutdown(wait=False)
            server.close()
            try:
                os.unlink(SOCKET_PATH)
            except OSError:
                pass
            try:
                os.unlink(PID_FILE)
            except OSError:
                pass


if __name__ == "__main__":
    daemon = LLMDaemon()
    daemon.run()
