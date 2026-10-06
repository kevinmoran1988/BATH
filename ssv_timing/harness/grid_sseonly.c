/* SSV micro-benchmark: time per (model length, sequence length), SSE and AVX2 kernels. Prints ns per call. */
#include "p7_config.h"
#include <stdio.h>
#include <time.h>
#include "easel.h"
#include "esl_alphabet.h"
#include "esl_random.h"
#include "esl_randomseq.h"
#include "esl_sq.h"
#include "hmmer.h"
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + 1e-9 * t.tv_nsec; }
int main(int argc, char **argv)
{
  int Ms[] = { 5, 16, 32, 33, 64, 100, 200, 400, 650, 1000, 2000, 3841 };
  int Ls[] = { 1, 5, 10, 30, 100, 300, 1000, 3000 };
  int nM = 12, nL = 8, mi, li, k, s, NS = 64;
  ESL_RANDOMNESS *r = esl_randomness_Create(7);
  ESL_ALPHABET   *abc = esl_alphabet_Create(eslAMINO);
  P7_BG          *bg  = p7_bg_Create(abc);
  float sc; volatile float sink = 0;
  p7_FLogsumInit();
  for (mi = 0; mi < nM; mi++) {
    int M = Ms[mi]; P7_HMM *hmm = NULL; P7_PROFILE *gm; P7_OPROFILE *oa;
    p7_hmm_Sample(r, M, abc, &hmm);
    gm = p7_profile_Create(M, abc); oa = p7_oprofile_Create(M, abc);
    p7_ProfileConfig(hmm, bg, gm, 400, p7_LOCAL); p7_oprofile_Convert(gm, oa);
    for (li = 0; li < nL; li++) {
      int L = Ls[li]; ESL_DSQ *dsq[64]; double ta = 1e9, ts = 1e9, t; int reps = 2000000 / (L * (M / 32 + 1)) + 20, rep;
      for (s = 0; s < NS; s++) { dsq[s] = malloc(L + 2); esl_rsq_xfIID(r, bg->f, abc->K, L, dsq[s]); }
      p7_oprofile_ReconfigLength(oa, L);
      for (rep = 0; rep < 5; rep++) {
        t = now(); for (k = 0; k < reps; k++) { p7_SSVFilter(dsq[k % NS], L, oa, &sc); sink += sc; } t = (now() - t) / reps; if (t < ta) ta = t;
        t = now(); for (k = 0; k < reps; k++) { p7_SSVFilter(dsq[k % NS], L, oa, &sc); sink += sc; } t = (now() - t) / reps; if (t < ts) ts = t;
      }
      printf("%d %d %.1f %.1f\n", M, L, ta * 1e9, ts * 1e9);
      for (s = 0; s < NS; s++) free(dsq[s]);
    }
    p7_oprofile_Destroy(oa); p7_profile_Destroy(gm); p7_hmm_Destroy(hmm);
  }
  return 0;
}
