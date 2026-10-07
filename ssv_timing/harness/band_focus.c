/* Focused SSV timing: one model length, a range of sequence lengths.
 *
 *   focus <M> <L,L,...> [nseq] [mode]
 *
 * mode "filter" (the default) times p7_SSVFilter().
 * mode "band" calls the band kernel calc_band_<Q>() directly. It needs a model
 *      that fits one band (Q <= 14 vectors) and the SSE-only build, where the
 *      band kernels are global symbols. It leaves get_xE() and the score
 *      conversion out of the measurement.
 *
 * Prints one line per sequence length:  M L ns_per_call
 * The model is sampled with a fixed seed, so every binary times the same one.
 * Each sequence length is timed over the same <nseq> random sequences, best of
 * 5 passes.
 *
 * Built with -DFOCUS_DISPATCH it times the SSE kernel of the default (AVX2)
 * build, p7_SSVFilter_sse(), instead; "band" mode is not available there.
 */
#include "p7_config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <emmintrin.h>
#include "easel.h"
#include "esl_alphabet.h"
#include "esl_random.h"
#include "esl_randomseq.h"
#include "hmmer.h"

#if defined(FOCUS_AVX)
#define OP_CREATE   p7_oprofile_Create_avx
#define OP_CONVERT  p7_oprofile_Convert_avx
#define OP_RECONFIG p7_oprofile_ReconfigLength_avx
#define OP_DESTROY  p7_oprofile_Destroy_avx
#define SSV         p7_SSVFilter_avx
#define INIT()      impl_Init()
#define FOCUS_DISPATCH
#elif defined(FOCUS_DISPATCH)
#define OP_CREATE   p7_oprofile_Create_sse
#define OP_CONVERT  p7_oprofile_Convert_sse
#define OP_RECONFIG p7_oprofile_ReconfigLength_sse
#define OP_DESTROY  p7_oprofile_Destroy_sse
#define SSV         p7_SSVFilter_sse
#define INIT()      impl_Init()
#else
#define OP_CREATE   p7_oprofile_Create
#define OP_CONVERT  p7_oprofile_Convert
#define OP_RECONFIG p7_oprofile_ReconfigLength
#define OP_DESTROY  p7_oprofile_Destroy
#define SSV         p7_SSVFilter
#define INIT()      p7_FLogsumInit()
typedef __m128i band_fn(const ESL_DSQ *, int, const P7_OPROFILE *, int, __m128i, __m128i);
extern band_fn calc_band_1, calc_band_2, calc_band_3, calc_band_4, calc_band_5, calc_band_6, calc_band_7,
               calc_band_8, calc_band_9, calc_band_10, calc_band_11, calc_band_12, calc_band_13, calc_band_14;
#endif

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + 1e-9 * t.tv_nsec; }

int
main(int argc, char **argv)
{
  int M, NS, band, L, s, k, rep; char *lp;
  ESL_RANDOMNESS *r   = esl_randomness_Create(7);
  ESL_ALPHABET   *abc = esl_alphabet_Create(eslAMINO);
  P7_BG          *bg  = p7_bg_Create(abc);
  P7_HMM         *hmm = NULL;
  P7_PROFILE     *gm;
  P7_OPROFILE    *om;
  float           sc;
  volatile float  sink = 0;

  if (argc < 3) { fprintf(stderr, "usage: %s <M> <L,L,...> [nseq] [filter|band]\n", argv[0]); return 1; }
  M  = atoi(argv[1]);
  NS = (argc > 3) ? atoi(argv[3]) : 64;
  band = (argc > 4 && strcmp(argv[4], "band") == 0);

  INIT();
  p7_hmm_Sample(r, M, abc, &hmm);
  gm = p7_profile_Create(M, abc);
  om = OP_CREATE(M, abc);
  p7_ProfileConfig(hmm, bg, gm, 400, p7_LOCAL);
  OP_CONVERT(gm, om);

#ifdef FOCUS_DISPATCH
  if (band) { fprintf(stderr, "band mode needs the SSE-only build\n"); return 1; }
#else
  band_fn *fs[15] = { NULL, calc_band_1, calc_band_2, calc_band_3, calc_band_4, calc_band_5, calc_band_6, calc_band_7,
                      calc_band_8, calc_band_9, calc_band_10, calc_band_11, calc_band_12, calc_band_13, calc_band_14 };
  int     Q      = p7O_NQB(om->M);
  __m128i beginv = _mm_set1_epi8(-128);
  if (band && Q > 14) { fprintf(stderr, "band mode needs a one-band model: M <= 224\n"); return 1; }
#endif

  for (lp = strtok(argv[2], ","); lp != NULL; lp = strtok(NULL, ","))
    {
      L = atoi(lp);
      ESL_DSQ **dsq  = malloc(sizeof(ESL_DSQ *) * NS);
      double    best = 1e9, t;
      int       reps = 2000000 / (L * (M / 32 + 1)) + 20;

      for (s = 0; s < NS; s++) { dsq[s] = malloc(L + 2); esl_rsq_xfIID(r, bg->f, abc->K, L, dsq[s]); }
      OP_RECONFIG(om, L);
      for (rep = 0; rep < 5; rep++)
        {
          t = now();
#ifndef FOCUS_DISPATCH
          if (band)
            for (k = 0; k < reps; k++) { __m128i x = fs[Q](dsq[k % NS], L, om, 0, beginv, beginv); sink += _mm_cvtsi128_si32(x); }
          else
#endif
            for (k = 0; k < reps; k++) { SSV(dsq[k % NS], L, om, &sc); sink += sc; }
          t = (now() - t) / reps;
          if (t < best) best = t;
        }
      printf("%d %d %.1f\n", M, L, best * 1e9);
      for (s = 0; s < NS; s++) free(dsq[s]);
      free(dsq);
    }

  OP_DESTROY(om); p7_profile_Destroy(gm); p7_hmm_Destroy(hmm);
  p7_bg_Destroy(bg); esl_alphabet_Destroy(abc); esl_randomness_Destroy(r);
  return 0;
}
