#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <vector>
#include <algorithm>
#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <cuda_bf16.h>
#include <cuda_fp8.h>
#include <torch/types.h>
#include <torch/extension.h>

#define WARP_SIZE 32
#define INT4(value) (reinterpret_cast<int4*>(&(value))[0])
#define FLOAT4(value) (reinterpret_cast<float4*>(&(value))[0])

// -------------------------------------- FP32 -------------------------------------- 
// Warp Reduce Sum
template<const int kWarpSize = WARP_SIZE>
__device__ __forceinline__ float warp_reduce_sum_f32(float val) {
  #pragma unroll
  for (int mask = kWarpSize >> 1; mask >= 1; mask >>= 1) {
    val += __shfl_xor_sync(0xffffffff, val, mask);
  }
  return val;
}

// SGEMV: Warp SGEMV K32
// 假设K为32的倍数，每个warp负责一行
// grid(M/4), block(32,4) blockDim.x=32=K, blockDim.y=4
// a: MxK, x: Kx1, y: Mx1, compute: y = a * x
__global__ void sgemv_k32_f32_kernel(float* a, float* x, float* y, int M, int K) {
  int tx = threadIdx.x;         // 0~31
  int ty = threadIdx.y;         // 0~4
  int bx = blockIdx.x;          // 0~M/4
  int lane = tx % WARP_SIZE;    // 0~31
  int m = bx * blockDim.y + ty; // (0~M/4) * 4 + (0~3)
  if (m < M) {
    float sum = 0.0f;
    int NUM_WARPS = (K + WARP_SIZE - 1) / WARP_SIZE;
    #pragma unroll
    for (int w = 0; w < NUM_WARPS; ++w) {
      // 若NUM_WARPS>=2，先将当前行的数据累加到第一个warp中
      int k = w * WARP_SIZE + lane;
      sum += a[m * K + k] * x[k];
    }
    sum = warp_reduce_sum_f32<WARP_SIZE>(sum);
    if (lane == 0) y[m] = sum;
  }
}

// SGEMV: Warp SGEMV K128 + Vec4
// 假设K为128的倍数 float4
// grid(M/4), block(32,4) blockDim.x=32=K, blockDim.y=4
// a: MxK, x: Kx1, y: Mx1, compute: y = a * x
__global__ void sgemv_k128_f32x4_kernel(float* a, float* x, float* y, int M, int K) {
  // 每个线程负责4个元素，一个warp覆盖128个元素
  int tx = threadIdx.x;         // 0~31
  int ty = threadIdx.y;         // 0~3
  int bx = blockIdx.x;          // 0~M/4
  int lane = tx % WARP_SIZE;    // 0~31
  int m = blockDim.y * bx + ty; // (0~M/4) * 4 + (0~3)
  
  if (m < M) {
    float sum = 0.0f;
    // process 4*WARP_SIZE elements per warp.
    int NUM_WARPS = (((K + WARP_SIZE - 1) / WARP_SIZE) + 4 - 1) / 4;
    #pragma unroll
    for (int w = 0; w < NUM_WARPS; ++w) {
      int k = (w * WARP_SIZE + lane) * 4;
      float4 reg_x = FLOAT4(x[k]);
      float4 reg_a = FLOAT4(a[m * K + k]);
      sum += (reg_a.x * reg_x.x + reg_a.y * reg_x.y 
            + reg_a.z * reg_x.z + reg_a.w * reg_x.w);
    }
    sum = warp_reduce_sum_f32<WARP_SIZE>(sum);
    if(lane == 0) y[m] = sum;
  }
}

// SGEMV: Warp SGEMV K16
// 假设K为16 < 32,每个warp负责2行，每行有16个元素
// NUM_THREADS=128, NUM_WARPS=NUM_THREADS/WARP_SIZE;
// NUM_ROWS=NUM_WARPS * ROW_PER_WARP, grid(M/NUM_ROWS), block(32,NUM_WARPS)
// a: MxK, x: Kx1, y: Mx1, compute: y = a * x
template<const int ROW_PER_WARP = 2> 
__global__ void sgemv_k16_f32_kernel(float* A, float* x, float* y, int M, int K) {
  constexpr int K_WARP_SIZE = (WARP_SIZE + ROW_PER_WARP - 1) / ROW_PER_WARP;
  int tx = threadIdx.x;       // 0~31
  int ty = threadIdx.y;       // 0~NUM_WARPS
  int bx = blockIdx.x;        // 0~M/NUM_ROWS (NUM_ROWS=NUM_WARPS * ROW_PER_WARP)
  int lane = tx % WARP_SIZE;  // 0~31
  int k = lane % K_WARP_SIZE; // 0~15
  // gloabl row of a: MxK and y:Mx1, blockDim.y=NUM_WARPS
  int m = (blockDim.y * bx + ty) * ROW_PER_WARP + lane / K_WARP_SIZE;
  if (m < M) {
    float sum = A[m * K + k] * x[k];
    sum = warp_reduce_sum_f32<K_WARP_SIZE>(sum);
    // 注意是k == 0，而不是lane == 0
    if(k == 0) y[m] = sum; 
  }
}

// --------------------- PyTorch bindings for custom kernel -----------------------
#define STRINGFY(str) #str
#define TORCH_BINDING_COMMON_EXTENSION(func) \
  m.def(STRINGFY(func), &func, STRINGFY(func));

#define CHECK_TORCH_TENSOR_DTYPE(T, th_type)                 \
if(((T).options().dtype() != (th_type))) {                   \
  std::cout << "Tensor Info:" << (T).options() << std::endl; \
  throw std::runtime_error("values must be "#th_type);       \
}

#define CHECK_TORCH_TENSOR_SHAPE(T, S0, S1)           \
if (((T).size(0) != (S0)) || ((T).size(1) != (S1))) { \
  throw std::runtime_error("Tensor size mismatch!");  \
}

#define ASSERT_K_IS_MULTIBLE_OF(V) \
if (K % (V) != 0) { throw std::runtime_error("K must be multiple of "#V); }

#define ASSERT_K_IS_EQUAL_OF(V) \
if (K != (V)) { throw std::runtime_error("K must be "#V);}

void sgemv_k32_f32(torch::Tensor a, torch::Tensor x, torch::Tensor y) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(x, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(y, torch::kFloat32)
  const int M = a.size(0);
  const int K = a.size(1);
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(x, K, 1)
  CHECK_TORCH_TENSOR_SHAPE(y, M, 1)
  ASSERT_K_IS_MULTIBLE_OF(32)

  dim3 block(32, 4);
  dim3 grid((M + 4 - 1) / 4);

  sgemv_k32_f32_kernel<<<grid, block>>>(
    reinterpret_cast<float*>(a.data_ptr()),
    reinterpret_cast<float*>(x.data_ptr()),
    reinterpret_cast<float*>(y.data_ptr()),
    M, K
  );
}

void sgemv_k128_f32x4(torch::Tensor a, torch::Tensor x, torch::Tensor y) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(x, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(y, torch::kFloat32)
  const int M = a.size(0);
  const int K = a.size(1);
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(x, K, 1)
  CHECK_TORCH_TENSOR_SHAPE(y, M, 1)
  ASSERT_K_IS_MULTIBLE_OF(128)
  
  dim3 block(32, 4);
  dim3 grid((M + 4 - 1) / 4);

  sgemv_k128_f32x4_kernel<<<grid, block>>>(
    reinterpret_cast<float*>(a.data_ptr()),
    reinterpret_cast<float*>(x.data_ptr()),
    reinterpret_cast<float*>(y.data_ptr()),
    M, K
  );
}

void sgemv_k16_f32(torch::Tensor a, torch::Tensor x, torch::Tensor y) {
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(x, torch::kFloat32)
  CHECK_TORCH_TENSOR_DTYPE(y, torch::kFloat32)
  const int M = a.size(0);
  const int K = a.size(1);
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(x, K, 1)
  CHECK_TORCH_TENSOR_SHAPE(y, M, 1)
  ASSERT_K_IS_EQUAL_OF(16)
  
  constexpr int NUM_THREADS = 128;
  constexpr int ROW_PER_WARP = 2;
  constexpr int NUM_WARPS = NUM_THREADS / WARP_SIZE; // 4
  constexpr int NUM_ROWS = NUM_WARPS * ROW_PER_WARP; // 4 * 2 = 8

  dim3 block(32, NUM_WARPS);
  dim3 grid((M + NUM_ROWS - 1) / NUM_ROWS);

  sgemv_k16_f32_kernel<ROW_PER_WARP><<<grid, block>>>(
    reinterpret_cast<float*>(a.data_ptr()),
    reinterpret_cast<float*>(x.data_ptr()),
    reinterpret_cast<float*>(y.data_ptr()),
    M, K
  );
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  TORCH_BINDING_COMMON_EXTENSION(sgemv_k32_f32)
  TORCH_BINDING_COMMON_EXTENSION(sgemv_k128_f32x4)
  TORCH_BINDING_COMMON_EXTENSION(sgemv_k16_f32)
}