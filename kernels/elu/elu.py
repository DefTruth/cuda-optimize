import torch
import time
from torch.utils.cpp_extension import load
from typing import Optional

torch.set_grad_enabled(False)

# Load the CUDA kernel as a Python module
lib = load(name='elu_lib',
           sources=['elu.cu'],
           extra_cuda_cflags=[
               "-O3",
               "-U__CUDA_NO_HALF_OPERATORS__",
               "-U__CUDA_NO_HALF_CONVERSIONS__",
               "-U__CUDA_NO_HALF2_OPERATORS__",
               "-U__CUDA_NO_BFLOAT16_CONVERSIONS__",
               "--expt-relaxed-constexpr",
               "--expt-extended-lambda",
               "--use_fast_math",
           ],
           extra_cflags=['-std=c++17'])

def run_benchmark(perf_func: callable, x: torch.Tensor, tag: str,
                  out: Optional[torch.Tensor] = None, warmup: int = 10,
                  iters: int = 1000, show_all: bool = False):
    if out is not None:
        out.fill_(0)
    # warmup
    for i in range(warmup):
        perf_func(x, out)
    torch.cuda.synchronize()
    start = time.time()
    # iters
    for i in range(iters):
        perf_func(x, out)
    torch.cuda.synchronize()
    end = time.time()
    total_time = (end - start) * 1000  # ms
    mean_time = total_time / iters
    out_info = f"out_{tag}"
    out_val = out.flatten().detach().cpu().numpy().tolist()[:2]
    out_val = [round(v, 8) for v in out_val]
    out_val = [f"{v:<12}" for v in out_val]
    print(f"{out_info:>18}: {out_val}, time:{mean_time:.8f}ms")
    if show_all: print(out)
    return out, mean_time

def torch_elu(x, out=None):
    if out is None:
        return torch.where(x > 0, x, 1.0 * (torch.exp(x) - 1))
    else:
        torch.where(x > 0, x, 1.0 * (torch.exp(x) - 1), out=out)
        return out

Ss = [1024, 2048, 4096]
Ks = [1024, 2048, 4096]
SKs = [(S, K) for S in Ss for K in Ks]

for (S, K) in SKs:
    print("-" * 85)
    print(" " * 40 + f"S={S}, K={K}")
    x = torch.randn((S, K)).cuda().float().contiguous()
    y = torch.zeros_like(x).cuda().float().contiguous()
    run_benchmark(lib.elu_f32, x, "f32", y)
    run_benchmark(lib.elu_f32x4, x, "f32x4", y)
    run_benchmark(torch_elu, x, "f32_th", y)
    print("-" * 85)
    x_f16 = x.half().contiguous()
    y_f16 = y.half().contiguous()
    run_benchmark(lib.elu_f16, x_f16, "f16", y_f16)
    run_benchmark(lib.elu_f16x2, x_f16, "f16x2", y_f16)
    run_benchmark(lib.elu_f16x8, x_f16, "f16x8", y_f16)
    run_benchmark(lib.elu_f16x8_pack, x_f16, "f16x8pack", y_f16)
    run_benchmark(torch_elu, x_f16, "f16_th", y_f16)
    print("-" * 85)