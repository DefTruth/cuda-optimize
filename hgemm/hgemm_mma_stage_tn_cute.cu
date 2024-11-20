#include <cuda.h>
#include <cublas_v2.h>
#include <stdlib.h>
#include <cute/tensor.hpp>
#include <float.h>

// TODO: thread block swizzle, cute hgemm nn
template <
      typename T, 
      int BM, 
      int BN, 
      int BK, 
      int kStage, 
      typename TiledMMA, 
      typename G2SCopyA, 
      typename G2SCopyB,
      typename SmemLayoutA, 
      typename SmemLayoutB, 
      typename SmemLayoutC,
      typename S2RCopyAtomA, 
      typename S2RCopyAtomB,
      typename R2SCopyAtomC, 
      typename S2GCopyAtomC, 
      typename S2GCopyC,
      const bool kBlockSwizzle>
__global__ void hgemm_mma_stages_tn_cute_kernel(
  const T *Aptr, const T *Bptr, T *Dptr, int m, int n, int k) {
  using namespace cute;
  // Initilize shared memory
  extern __shared__ T shm_data[];

  T *Ashm = shm_data;
  T *Bshm = shm_data + cute::cosize(SmemLayoutA{});

  // Initilize thread block
  int idx = threadIdx.x;
  // int ix = blockIdx.x;
  // BLOCK_SWIZZLE 0/1 control use block swizzle or not.
  int ix = ((int) kBlockSwizzle) * blockIdx.z * gridDim.x + blockIdx.x;
  int iy = blockIdx.y;

  if (iy * BM >= m || ix * BN >= n) return;

  // use Tensor notation to represent device pointer + dimension
  Tensor A = make_tensor(make_gmem_ptr(Aptr), make_shape(m, k), make_stride(k, Int<1>{}));
  Tensor B = make_tensor(make_gmem_ptr(Bptr), make_shape(n, k), make_stride(k, Int<1>{}));
  Tensor D = make_tensor(make_gmem_ptr(Dptr), make_shape(m, n), make_stride(n, Int<1>{}));

  // slice the tensor to small one which is used for current thread block.
  Tensor gA = local_tile(A, make_tile(Int<BM>{}, Int<BK>{}), make_coord(iy, _)); // (BM, BK, num_tile_k)
  Tensor gB = local_tile(B, make_tile(Int<BN>{}, Int<BK>{}), make_coord(ix, _)); // (BN, BK, num_tile_k)
  Tensor gD = local_tile(D, make_tile(Int<BM>{}, Int<BN>{}), make_coord(iy, ix));// (BM, BN) 

  // shared memory
  auto sA = make_tensor(make_smem_ptr(Ashm), SmemLayoutA{}); // (BM, BK, kStage)
  auto sB = make_tensor(make_smem_ptr(Bshm), SmemLayoutB{}); // (BN, BK, kStage)

  // dispatch TileA/TileB/TileC mma tensor into thread fragment via partition
  TiledMMA tiled_mma;
  auto thr_mma = tiled_mma.get_slice(threadIdx.x);
  // auto tCsA = thr_mma.partition_A(sA); // (MMA,MMA_M,MMA_K,kStage)
  // auto tCsB = thr_mma.partition_B(sB); // (MMA,MMA_N,MMA_K,kStage)
  auto tCgD = thr_mma.partition_C(gD);    // (MMA, MMA_M, MMA_N)

  auto tCrA = thr_mma.partition_fragment_A(gA(_, _, 0)); // (MMA, MMA_M, MMA_K)
  auto tCrB = thr_mma.partition_fragment_B(gB(_, _, 0)); // (MMA, MMA_N, MMA_K)
  auto tCrD = thr_mma.partition_fragment_C(gD);          // (MMA, MMA_M, MMA_N)
  clear(tCrD);

  // from global memory to shared memory
  G2SCopyA g2s_tiled_copy_a;
  auto g2s_thr_copy_a = g2s_tiled_copy_a.get_slice(idx);
  auto tAgA_copy = g2s_thr_copy_a.partition_S(gA); // (CPY, CPY_M, CPY_K, num_tile_k)
  auto tAsA_copy = g2s_thr_copy_a.partition_D(sA); // (CPY, CPY_M, CPY_K, kStage)

  G2SCopyB g2s_tiled_copy_b;
  auto g2s_thr_copy_b = g2s_tiled_copy_b.get_slice(idx);
  auto tBgB_copy = g2s_thr_copy_b.partition_S(gB); // (CPY, CPY_N, CPY_K, num_tile_k)
  auto tBsB_copy = g2s_thr_copy_b.partition_D(sB); // (CPY, CPY_N, CPY_K, kStage)

  // from shared memory to register, use tiled_mma to generate tiled_copy
  auto s2r_tiled_copy_a = make_tiled_copy_A(S2RCopyAtomA{}, tiled_mma);
  auto s2r_thr_copy_a = s2r_tiled_copy_a.get_slice(idx);
  auto tAsA = s2r_thr_copy_a.partition_S(sA);   // (CPY, CPY_M, CPY_K, kStage)
  auto tCrA_view = s2r_thr_copy_a.retile_D(tCrA); // (CPY, CPY_M, CPY_K)

  auto s2r_tiled_copy_b = make_tiled_copy_B(S2RCopyAtomB{}, tiled_mma);
  auto s2r_thr_copy_b = s2r_tiled_copy_b.get_slice(idx);
  auto tBsB = s2r_thr_copy_b.partition_S(sB);   // (CPY, CPY_N, CPY_K, kStage)
  auto tCrB_view = s2r_thr_copy_b.retile_D(tCrB); // (CPY, CPY_N, CPY_K)

  /* PREFETCH */
  // submit kStage - 1 tile
  // gmem -> shm
  int itile_to_read = 0;
  int ismem_read = 0;
  int ismem_write = 0;

  #pragma unroll
  for (int istage = 0; istage < kStage - 1; ++istage) {
    cute::copy(g2s_tiled_copy_a, tAgA_copy(_, _, _, istage),
               tAsA_copy(_, _, _, istage));
    cute::copy(g2s_tiled_copy_b, tBgB_copy(_, _, _, istage),
               tBsB_copy(_, _, _, istage));
    cp_async_fence();

    ++itile_to_read;
    ++ismem_write;
  }

  // wait one submitted gmem->smem done
  cp_async_wait<kStage - 2>();
  __syncthreads();

  int ik = 0;
  // smem -> reg
  // tAsA: (CPY, CPY_M, CPY_K, kStage) tCrA_view: (CPY, CPY_M, CPY_K)
  cute::copy(s2r_tiled_copy_a, tAsA(_, _, ik, ismem_read), tCrA_view(_, _, ik)); 
  cute::copy(s2r_tiled_copy_b, tBsB(_, _, ik, ismem_read), tCrB_view(_, _, ik));

  // loop over k: i. load tile, ii. mma
  int ntile = k / BK;
  #pragma unroll 1
  for (int itile = 0; itile < ntile; ++itile) {
    int nk = size<2>(tCrA); // (MMA, MMA_M, MMA_K)

    #pragma unroll
    for (int ik = 0; ik < nk; ++ik) {
      int ik_next = (ik + 1) % nk;
      
      if (ik == nk - 1) {
        cp_async_wait<kStage - 2>();
        __syncthreads();

        ismem_read = (ismem_read + 1) % kStage;
      }
      
      // shm -> reg s[itile][ik + 1] -> r[ik + 1]
      cute::copy(s2r_tiled_copy_a, tAsA(_, _, ik_next, ismem_read), // tAsA: (CPY, CPY_M, CPY_K, kStage)
                 tCrA_view(_, _, ik_next));                         // tCrA_view: (CPY, CPY_M, CPY_K)
      cute::copy(s2r_tiled_copy_b, tBsB(_, _, ik_next, ismem_read), // tBsB: (CPY, CPY_M, CPY_K, kStage)
                 tCrB_view(_, _, ik_next));                         // tCrB_view: (CPY, CPY_M, CPY_K)

      if (ik == 0) {
        if (itile_to_read < ntile) {
          cute::copy(g2s_tiled_copy_a, tAgA_copy(_, _, _, itile_to_read),
              tAsA_copy(_, _, _, ismem_write));
          cute::copy(g2s_tiled_copy_b, tBgB_copy(_, _, _, itile_to_read),
              tBsB_copy(_, _, _, ismem_write));

          ++itile_to_read;
          ismem_write = (ismem_write + 1) % kStage;
        }

        cp_async_fence();
      }

      cute::gemm(tiled_mma, tCrD, tCrA(_, _, ik), tCrB(_, _, ik), tCrD);
    }  // for ik
  }

  // use less shared memory as a scratchpad tile to use large wide instuction
  // Dreg -> shm -> reg -> global
  auto sC = make_tensor(sA(_, _, ismem_read).data(), SmemLayoutC{});

  auto r2s_tiled_copy_c = make_tiled_copy_C(R2SCopyAtomC{}, tiled_mma);
  auto r2s_thr_copy_c = r2s_tiled_copy_c.get_slice(idx);
  auto tCrC_r2s = r2s_thr_copy_c.retile_S(tCrD);   // (CPY, CPY_M, CPY_N)
  auto tCsC_r2s = r2s_thr_copy_c.partition_D(sC);  // (CPY, _1, _1, pipe)

  S2GCopyC s2g_tiled_copy_c;
  auto s2g_thr_copy_c = s2g_tiled_copy_c.get_thread_slice(idx);
  auto tCsC_s2g = s2g_thr_copy_c.partition_S(sC);  // (CPY, _1, _1, pipe)
  auto tCgC_s2g = s2g_thr_copy_c.partition_D(gD);  // (CPY, CPY_M, CPY_N)

  auto tCgC_s2gx = group_modes<1, 3>(tCgC_s2g);  // (CPY_, CPY_MN)
  auto tCrC_r2sx = group_modes<1, 3>(tCrC_r2s);  // (CPY_, CPY_MN)

  int step = size<3>(tCsC_r2s);  // pipe
  #pragma unroll
  for (int i = 0; i < size<1>(tCrC_r2sx); i += step) {
    // reg -> shm
    #pragma unroll
    for (int j = 0; j < step; ++j) {
      // we add a temp tensor to cope with accumulator and output data type
      // difference
      auto t = make_tensor_like<T>(tCrC_r2sx(_, i + j));
      cute::copy(tCrC_r2sx(_, i + j), t);

      cute::copy(r2s_tiled_copy_c, t, tCsC_r2s(_, 0, 0, j));
    }
    __syncthreads();

    #pragma unroll
    // shm -> global
    for (int j = 0; j < step; ++j) {
      cute::copy(s2g_tiled_copy_c, tCsC_s2g(_, 0, 0, j), tCgC_s2gx(_, i + j));
    }
    __syncthreads();
  } // end for 
}

template <typename T, 
          const int K_STAGE = 2, 
          const bool BLOCK_SWIZZLE = false, 
          const int SWIZZLE_STRIDE = 2048>
void launch_hgemm_mma_stages_tn_cute(const T *a, const T *b, T *c, int M, int N, int K) {
  using namespace cute;

  auto BM = Int<128>{};
  auto BN = Int<256>{};
  auto BK = Int<32>{};
  auto KStage = Int<K_STAGE>{}; // default 2
  auto kSmemLayoutCBatch = Int<4>{};

  // Define the smem layouts
  using SmemLayoutAtom = decltype(
    composition(
      Swizzle<3, 3, 3>{}, 
      make_layout(make_shape(Int<8>{}, Int<BK>{}), make_stride(Int<BK>{}, Int<1>{}))
    )
  );
  using SmemLayoutA = decltype(
    tile_to_shape(SmemLayoutAtom{}, make_shape(Int<BM>{}, Int<BK>{}, Int<KStage>{}))
  );
  using SmemLayoutB = decltype(
    tile_to_shape(SmemLayoutAtom{}, make_shape(Int<BN>{}, Int<BK>{}, Int<KStage>{}))
  ); // (m,n) -> smem_idx
  
  // mma
  using mma_op = SM80_16x8x16_F16F16F16F16_TN;
  using mma_traits = MMA_Traits<mma_op>;
  using mma_atom = MMA_Atom<mma_traits>;
  static constexpr int kMmaEURepeatM = 2;
  static constexpr int kMmaEURepeatN = 2;
  static constexpr int kMmaEURepeatK = 1;

  using mma_atom_shape = mma_traits::Shape_MNK;
  static constexpr int kMmaPM = 1 * kMmaEURepeatM * get<0>(mma_atom_shape{});
  static constexpr int kMmaPN = 2 * kMmaEURepeatN * get<1>(mma_atom_shape{});
  static constexpr int kMmaPK = 1 * kMmaEURepeatK * get<2>(mma_atom_shape{});
  using MMA_EU_RepeatT = decltype(make_layout(make_shape(
    Int<kMmaEURepeatM>{}, Int<kMmaEURepeatN>{}, Int<kMmaEURepeatK>{})));
  using MMA_P_T = Tile<Int<kMmaPM>, Int<kMmaPN>, Int<kMmaPK>>;
  using MMA = decltype(make_tiled_mma(mma_atom{}, MMA_EU_RepeatT{}, MMA_P_T{}));
  
  // copy from global memory to shared memory
  using g2s_copy_op = SM80_CP_ASYNC_CACHEGLOBAL<cute::uint128_t>;
  using g2s_copy_traits = Copy_Traits<g2s_copy_op>;
  using g2s_copy_atom = Copy_Atom<g2s_copy_traits, T>;
  using G2SCopyA =
    decltype(make_tiled_copy(g2s_copy_atom{},
             make_layout(make_shape(Int<32>{}, Int<4>{}), // Thr layout 32x4 k-major
                         make_stride(Int<4>{}, Int<1>{})),
             make_layout(make_shape(Int<1>{}, Int<8>{})))); // Val layout 1x8
  using G2SCopyB = G2SCopyA;

  // copy from shared memory to register
  // use mma tiled ,so no tiled here
  using s2r_copy_op = SM75_U32x4_LDSM_N;
  using s2r_copy_traits = Copy_Traits<s2r_copy_op>;
  using s2r_copy_atom = Copy_Atom<s2r_copy_traits, T>;
  using S2RCopyAtomA = s2r_copy_atom;
  using S2RCopyAtomB = s2r_copy_atom;

  // epilogue: register to global via shared memory
  using SmemLayoutAtomC = decltype(
    composition(
      Swizzle<3, 3, 3>{}, 
      make_layout(make_shape(Int<kMmaPM>{}, Int<kMmaPN>{}), make_stride(Int<kMmaPN>{}, Int<1>{})))
    );
  using SmemLayoutC = decltype(
    tile_to_shape(
      SmemLayoutAtomC{}, 
      make_shape(Int<kMmaPM>{}, Int<kMmaPN>{}, Int<kSmemLayoutCBatch>{})
    )
  );

  static_assert(
    size<0>(SmemLayoutA{}) * size<1>(SmemLayoutA{}) >= size(SmemLayoutC{}),
    "C shared memory request is large than A's one pipe"
  );

  using R2SCopyAtomC = Copy_Atom<UniversalCopy<int>, T>;

  using S2GCopyAtomC = Copy_Atom<UniversalCopy<cute::uint128_t>, T>;
  using S2GCopyC = decltype(
    make_tiled_copy(
      S2GCopyAtomC{},
      make_layout(make_shape(Int<32>{}, Int<4>{}), make_stride(Int<4>{}, Int<1>{})),
      make_layout(make_shape(Int<1>{}, Int<8>{}))
    )
  );

  // Apply thread block swizzle
  int N_SWIZZLE = (N + (SWIZZLE_STRIDE) - 1) / (SWIZZLE_STRIDE);
  int BX = (N + BN - 1) / BN;
  N_SWIZZLE = BLOCK_SWIZZLE ? N_SWIZZLE : 1;
  BX = BLOCK_SWIZZLE ? (BX + N_SWIZZLE - 1) / N_SWIZZLE : BX;
  int BY = (M + BM - 1) / BM;
  
  dim3 block(size(MMA{}));
  // dim3 grid(BX, BY);
  dim3 grid(BX, BY, N_SWIZZLE);

  // C_shm is shared with A_shm and B_shm
  static constexpr int shm_size_AB =
    cute::cosize(SmemLayoutA{}) + cute::cosize(SmemLayoutB{});
  static constexpr int shm_size_C = cute::cosize(SmemLayoutC{});
  static constexpr int kShmSize =
    cute::max(shm_size_AB, shm_size_C) * sizeof(T);

  int shm_size = kShmSize;

  cudaFuncSetAttribute(
    hgemm_mma_stages_tn_cute_kernel<
      T, 
      BM, BN, BK, 
      KStage, 
      MMA, 
      G2SCopyA, 
      G2SCopyB, 
      SmemLayoutA, 
      SmemLayoutB, 
      SmemLayoutC, 
      S2RCopyAtomA, 
      S2RCopyAtomB, 
      R2SCopyAtomC, 
      S2GCopyAtomC, 
      S2GCopyC,
      BLOCK_SWIZZLE
    >,
    cudaFuncAttributeMaxDynamicSharedMemorySize, 
    shm_size
  );
  
  hgemm_mma_stages_tn_cute_kernel<
    T, 
    BM, BN, BK, 
    KStage, 
    MMA, 
    G2SCopyA, 
    G2SCopyB, 
    SmemLayoutA, 
    SmemLayoutB, 
    SmemLayoutC, 
    S2RCopyAtomA, 
    S2RCopyAtomB, 
    R2SCopyAtomC, 
    S2GCopyAtomC, 
    S2GCopyC,
    BLOCK_SWIZZLE
  ><<<grid, block, shm_size>>>(a, b, c, M, N, K);
}

// For torch binding, dynamic block swizzle stride
template <typename T, 
          const int K_STAGE = 2, 
          const bool BLOCK_SWIZZLE = false>
void launch_hgemm_mma_stages_swizzle_tn_cute(
  const T *a, const T *b, T *c, int M, int N, int K, 
  int swizzle_stride = 2048) {
  using namespace cute;

  auto BM = Int<128>{};
  auto BN = Int<256>{};
  auto BK = Int<32>{};
  auto KStage = Int<K_STAGE>{}; // default 2
  auto kSmemLayoutCBatch = Int<4>{};

  // Define the smem layouts
  using SmemLayoutAtom = decltype(
    composition(
      Swizzle<3, 3, 3>{}, 
      make_layout(make_shape(Int<8>{}, Int<BK>{}), make_stride(Int<BK>{}, Int<1>{}))
    )
  );
  using SmemLayoutA = decltype(
    tile_to_shape(SmemLayoutAtom{}, make_shape(Int<BM>{}, Int<BK>{}, Int<KStage>{}))
  );
  using SmemLayoutB = decltype(
    tile_to_shape(SmemLayoutAtom{}, make_shape(Int<BN>{}, Int<BK>{}, Int<KStage>{}))
  ); // (m,n) -> smem_idx
  
  // mma
  using mma_op = SM80_16x8x16_F16F16F16F16_TN;
  using mma_traits = MMA_Traits<mma_op>;
  using mma_atom = MMA_Atom<mma_traits>;
  static constexpr int kMmaEURepeatM = 2;
  static constexpr int kMmaEURepeatN = 2;
  static constexpr int kMmaEURepeatK = 1;

  using mma_atom_shape = mma_traits::Shape_MNK;
  static constexpr int kMmaPM = 1 * kMmaEURepeatM * get<0>(mma_atom_shape{});
  static constexpr int kMmaPN = 2 * kMmaEURepeatN * get<1>(mma_atom_shape{});
  static constexpr int kMmaPK = 1 * kMmaEURepeatK * get<2>(mma_atom_shape{});
  using MMA_EU_RepeatT = decltype(make_layout(make_shape(
    Int<kMmaEURepeatM>{}, Int<kMmaEURepeatN>{}, Int<kMmaEURepeatK>{})));
  using MMA_P_T = Tile<Int<kMmaPM>, Int<kMmaPN>, Int<kMmaPK>>;
  using MMA = decltype(make_tiled_mma(mma_atom{}, MMA_EU_RepeatT{}, MMA_P_T{}));
  
  // copy from global memory to shared memory
  using g2s_copy_op = SM80_CP_ASYNC_CACHEGLOBAL<cute::uint128_t>;
  using g2s_copy_traits = Copy_Traits<g2s_copy_op>;
  using g2s_copy_atom = Copy_Atom<g2s_copy_traits, T>;
  using G2SCopyA =
    decltype(make_tiled_copy(g2s_copy_atom{},
             make_layout(make_shape(Int<32>{}, Int<4>{}), // Thr layout 32x4 k-major
                         make_stride(Int<4>{}, Int<1>{})),
             make_layout(make_shape(Int<1>{}, Int<8>{})))); // Val layout 1x8
  using G2SCopyB = G2SCopyA;

  // copy from shared memory to register
  // use mma tiled ,so no tiled here
  using s2r_copy_op = SM75_U32x4_LDSM_N;
  using s2r_copy_traits = Copy_Traits<s2r_copy_op>;
  using s2r_copy_atom = Copy_Atom<s2r_copy_traits, T>;
  using S2RCopyAtomA = s2r_copy_atom;
  using S2RCopyAtomB = s2r_copy_atom;

  // epilogue: register to global via shared memory
  using SmemLayoutAtomC = decltype(
    composition(
      Swizzle<3, 3, 3>{}, 
      make_layout(make_shape(Int<kMmaPM>{}, Int<kMmaPN>{}), make_stride(Int<kMmaPN>{}, Int<1>{})))
    );
  using SmemLayoutC = decltype(
    tile_to_shape(
      SmemLayoutAtomC{}, 
      make_shape(Int<kMmaPM>{}, Int<kMmaPN>{}, Int<kSmemLayoutCBatch>{})
    )
  );

  static_assert(
    size<0>(SmemLayoutA{}) * size<1>(SmemLayoutA{}) >= size(SmemLayoutC{}),
    "C shared memory request is large than A's one pipe"
  );

  using R2SCopyAtomC = Copy_Atom<UniversalCopy<int>, T>;

  using S2GCopyAtomC = Copy_Atom<UniversalCopy<cute::uint128_t>, T>;
  using S2GCopyC = decltype(
    make_tiled_copy(
      S2GCopyAtomC{},
      make_layout(make_shape(Int<32>{}, Int<4>{}), make_stride(Int<4>{}, Int<1>{})),
      make_layout(make_shape(Int<1>{}, Int<8>{}))
    )
  );

  // Apply thread block swizzle
  int N_SWIZZLE = (N + (swizzle_stride) - 1) / (swizzle_stride);
  int BX = (N + BN - 1) / BN;
  N_SWIZZLE = BLOCK_SWIZZLE ? N_SWIZZLE : 1;
  BX = BLOCK_SWIZZLE ? (BX + N_SWIZZLE - 1) / N_SWIZZLE : BX;
  int BY = (M + BM - 1) / BM;
  
  dim3 block(size(MMA{}));
  // dim3 grid(BX, BY);
  dim3 grid(BX, BY, N_SWIZZLE);

  // C_shm is shared with A_shm and B_shm
  static constexpr int shm_size_AB =
    cute::cosize(SmemLayoutA{}) + cute::cosize(SmemLayoutB{});
  static constexpr int shm_size_C = cute::cosize(SmemLayoutC{});
  static constexpr int kShmSize =
    cute::max(shm_size_AB, shm_size_C) * sizeof(T);

  int shm_size = kShmSize;

  cudaFuncSetAttribute(
    hgemm_mma_stages_tn_cute_kernel<
      T, 
      BM, BN, BK, 
      KStage, 
      MMA, 
      G2SCopyA, 
      G2SCopyB, 
      SmemLayoutA, 
      SmemLayoutB, 
      SmemLayoutC, 
      S2RCopyAtomA, 
      S2RCopyAtomB, 
      R2SCopyAtomC, 
      S2GCopyAtomC, 
      S2GCopyC,
      BLOCK_SWIZZLE
    >,
    cudaFuncAttributeMaxDynamicSharedMemorySize, 
    shm_size
  );
  
  hgemm_mma_stages_tn_cute_kernel<
    T, 
    BM, BN, BK, 
    KStage, 
    MMA, 
    G2SCopyA, 
    G2SCopyB, 
    SmemLayoutA, 
    SmemLayoutB, 
    SmemLayoutC, 
    S2RCopyAtomA, 
    S2RCopyAtomB, 
    R2SCopyAtomC, 
    S2GCopyAtomC, 
    S2GCopyC,
    BLOCK_SWIZZLE
  ><<<grid, block, shm_size>>>(a, b, c, M, N, K);
}

// build cpp binary
#ifndef NO_CUTE_HGEMM_BIN

#include "utils.h"

int main() {
  using T = cute::half_t;
  using namespace cute;

  const int test_num = 64;
  int M_list[test_num];
  int N_list[test_num];
  int K_list[test_num];

  for (int i = 0; i < test_num; i++) {
    M_list[i] = (i + 1) * 256;
    N_list[i] = (i + 1) * 256;
    K_list[i] = (i + 1) * 256;
  }

  const int outer_repeat = 10, inner_repeat = 1;

  printf("ALGO = CuTe HGEMM, TN, STAGES=2, SMEM SWIZZLE=<3, 3, 3>, BLOCK SWIZZLE=2048\n");
  for (int j = 0; j < 5; j++) {
    int M = M_list[j], N = N_list[j], K = K_list[j];
    float max_error = gemm_error_check_tn<T>(
      launch_hgemm_mma_stages_tn_cute<T, 2, true, 2048>, 
      M, N, K);
    printf("M N K = %6d %6d %6d, ", M, N, K);
    printf("Max Error = %f\n", max_error);
  }

  for (int j = 0; j < test_num; j++) {
    int M = M_list[j], N = N_list[j], K = K_list[j];
 
    double max_sec = 0.0;
    double min_sec = DBL_MAX;
    double total_sec = 0.0;

    for (int k = 0; k < outer_repeat; k++) {
      double this_sec = perf_gemm<T>(
        launch_hgemm_mma_stages_tn_cute<T, 2, true, 2048>, 
        M, N, K, inner_repeat);
      max_sec = max(max_sec, this_sec);
      min_sec = min(min_sec, this_sec);
      total_sec += this_sec;
    }

    double avg_sec = total_sec / outer_repeat;
    double avg_Tflops = ((double)M) * N * K * 2 * 1e-12 / avg_sec;

    printf("M N K = %6d %6d %6d, ", M, N, K);
    printf("Time = %12.8lf %12.8lf %12.8lf s, ", min_sec, avg_sec, max_sec);
    printf("AVG Performance = %10.4lf Tflops\n", avg_Tflops);
  }

  return 0;
}
// build torch python binding
#else 
#include <torch/types.h>
#include <torch/extension.h>
// --------------------- PyTorch bindings for custom kernel -----------------------
#define STRINGFY(str) #str
#define TORCH_BINDING_COMMON_EXTENSION(func)   \
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

#define LAUNCH_HGEMM_MMA_STAGES_CUTE_NO_SWIZZLE_TN(stages)             \
  launch_hgemm_mma_stages_swizzle_tn_cute<half, (stages), false>(      \
    reinterpret_cast<half*>(a.data_ptr()),                             \
    reinterpret_cast<half*>(b.data_ptr()),                             \
    reinterpret_cast<half*>(c.data_ptr()),                             \
    M, N, K, 2048                                                      \
  );


#define LAUNCH_HGEMM_MMA_STAGES_CUTE_SWIZZLE_TN(stages, stride)        \
  launch_hgemm_mma_stages_swizzle_tn_cute<half, (stages), true>(       \
    reinterpret_cast<half*>(a.data_ptr()),                             \
    reinterpret_cast<half*>(b.data_ptr()),                             \
    reinterpret_cast<half*>(c.data_ptr()),                             \
    M, N, K, (stride)                                                  \
  );


// support thread block swizzle
void hgemm_mma_stages_tn_cute(
  torch::Tensor a, torch::Tensor b, torch::Tensor c,
  int stages, bool swizzle, int swizzle_stride) {
  // swizzle, swizzle_stride unused now
  CHECK_TORCH_TENSOR_DTYPE(a, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(b, torch::kHalf)
  CHECK_TORCH_TENSOR_DTYPE(c, torch::kHalf)
  const int M = a.size(0);
  const int K = a.size(1);
  const int N = b.size(1); 
  CHECK_TORCH_TENSOR_SHAPE(a, M, K)
  CHECK_TORCH_TENSOR_SHAPE(b, K, N)
  CHECK_TORCH_TENSOR_SHAPE(c, M, N)

  if (swizzle) {
    switch (stages)
    {
      case 2: 
        LAUNCH_HGEMM_MMA_STAGES_CUTE_SWIZZLE_TN(2, swizzle_stride);
        break;
      case 3: 
        LAUNCH_HGEMM_MMA_STAGES_CUTE_SWIZZLE_TN(3, swizzle_stride);
        break;
      case 4: 
        LAUNCH_HGEMM_MMA_STAGES_CUTE_SWIZZLE_TN(4, swizzle_stride);
        break;
      default:
        LAUNCH_HGEMM_MMA_STAGES_CUTE_SWIZZLE_TN(2, swizzle_stride);
        break;
    }
  } else {
    switch (stages) {
      case 2:
        LAUNCH_HGEMM_MMA_STAGES_CUTE_NO_SWIZZLE_TN(2)
        break;
      case 3:
        LAUNCH_HGEMM_MMA_STAGES_CUTE_NO_SWIZZLE_TN(3)
        break;
      case 4:
        LAUNCH_HGEMM_MMA_STAGES_CUTE_NO_SWIZZLE_TN(4)
        break;
      default:
        LAUNCH_HGEMM_MMA_STAGES_CUTE_NO_SWIZZLE_TN(2)
        break;
    }
  }
}
#endif
