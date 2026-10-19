### Throughput (llama-bench, cold context)

| Model | Size | Test | tok/s | ± |
|---|---:|---|---:|---:|
| Qwen3-0.6B-Base.Q8_0 | 0.63 GB | pp512 | 3646.7 | 10.1 |
| Qwen3-0.6B-Base.Q8_0 | 0.63 GB | tg128 | 136.7 | 5.2 |
| Qwen3-1.7B-Base.Q4_K_M | 1.10 GB | pp512 | 1264.2 | 2.7 |
| Qwen3-1.7B-Base.Q4_K_M | 1.10 GB | tg128 | 89.2 | 2.6 |
| Qwen3-4B-Base.Q4_K_M | 2.49 GB | pp512 | 480.4 | 30.2 |
| Qwen3-4B-Base.Q4_K_M | 2.49 GB | tg128 | 44.3 | 1.4 |

### Few-token prefill on a warm KV cache (llama-bench `-d`)

Time for a k-token prefill with d tokens already in the cache. The last prefill token's logits
give the first suggested token, so this is the model-side time to first token.

| Model | Test | tok/s | ms per call |
|---|---|---:|---:|
| Qwen3-0.6B-Base.Q8_0 | pp1 @ d512 | 136.3 | 7.3 |
| Qwen3-0.6B-Base.Q8_0 | pp4 @ d512 | 497.7 | 8.0 |
| Qwen3-0.6B-Base.Q8_0 | pp8 @ d512 | 732.2 | 10.9 |
| Qwen3-0.6B-Base.Q8_0 | tg8 @ d512 | 141.7 | 56.5 |
| Qwen3-0.6B-Base.Q8_0 | pp1 @ d2048 | 96.1 | 10.4 |
| Qwen3-0.6B-Base.Q8_0 | pp4 @ d2048 | 352.4 | 11.4 |
| Qwen3-0.6B-Base.Q8_0 | pp8 @ d2048 | 712.9 | 11.2 |
| Qwen3-0.6B-Base.Q8_0 | tg8 @ d2048 | 120.6 | 66.3 |
| Qwen3-1.7B-Base.Q4_K_M | pp1 @ d512 | 91.6 | 10.9 |
| Qwen3-1.7B-Base.Q4_K_M | pp4 @ d512 | 271.6 | 14.7 |
| Qwen3-1.7B-Base.Q4_K_M | pp8 @ d512 | 506.9 | 15.8 |
| Qwen3-1.7B-Base.Q4_K_M | tg8 @ d512 | 93.3 | 85.8 |
| Qwen3-1.7B-Base.Q4_K_M | pp1 @ d2048 | 75.8 | 13.2 |
| Qwen3-1.7B-Base.Q4_K_M | pp4 @ d2048 | 244.7 | 16.3 |
| Qwen3-1.7B-Base.Q4_K_M | pp8 @ d2048 | 433.6 | 18.4 |
| Qwen3-1.7B-Base.Q4_K_M | tg8 @ d2048 | 80.0 | 99.9 |
| Qwen3-4B-Base.Q4_K_M | pp1 @ d512 | 43.4 | 23.0 |
| Qwen3-4B-Base.Q4_K_M | pp4 @ d512 | 124.5 | 32.1 |
| Qwen3-4B-Base.Q4_K_M | pp8 @ d512 | 232.0 | 34.5 |
| Qwen3-4B-Base.Q4_K_M | tg8 @ d512 | 44.6 | 179.3 |
| Qwen3-4B-Base.Q4_K_M | pp1 @ d2048 | 40.5 | 24.7 |
| Qwen3-4B-Base.Q4_K_M | pp4 @ d2048 | 116.2 | 34.4 |
| Qwen3-4B-Base.Q4_K_M | pp8 @ d2048 | 203.1 | 39.4 |
| Qwen3-4B-Base.Q4_K_M | tg8 @ d2048 | 41.7 | 191.6 |

### Simulated keystroke loop (llama-server, cache_prompt, 1 slot)

| Model | Cold prefill | Prefill tokens/keystroke p50 (max) | TTFT p50 | TTFT p90 | TTFT max | 8-token suggestion p50 | p90 | Decode ms/token p50 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Qwen3-0.6B-Base.Q8_0.gguf | 412 tok in 293 ms | 1 (2) | 12.2 | 16.5 | 24.7 | 68.2 | 72.1 | 8.02 |
| Qwen3-1.7B-Base.Q4_K_M.gguf | 412 tok in 444 ms | 1 (2) | 15.7 | 20.6 | 23.5 | 97.2 | 103.0 | 11.57 |
| Qwen3-4B-Base.Q4_K_M.gguf | 412 tok in 833 ms | 1 (2) | 24.7 | 32.7 | 39.6 | 186.1 | 209.2 | 22.99 |

