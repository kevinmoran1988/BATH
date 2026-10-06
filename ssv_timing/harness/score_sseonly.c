/* SSV harness: scores from p7_SSVFilter_sse and p7_SSVFilter_avx on random
 * and profile-emitted sequences, printed for old/new comparison and timed. */
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
  int Ms[] = { 5, 16, 33, 64, 109, 200, 400, 650, 1000, 2000, 3841 };
  int nseq = atoi(argv[1]), reps = atoi(argv[2]), mi, n, k, st1, st2;
  ESL_RANDOMNESS *r = esl_randomness_Create(42);
  ESL_ALPHABET   *abc = esl_alphabet_Create(eslAMINO);
  P7_BG          *bg  = p7_bg_Create(abc);
  double tsse = 0, tavx = 0, t;
  float sc1, sc2;
  p7_FLogsumInit();
  for (mi = 0; mi < 11; mi++) {
    int M = Ms[mi];
    P7_HMM *hmm = NULL; P7_PROFILE *gm; P7_OPROFILE *om; ESL_SQ *sq = esl_sq_CreateDigital(abc);
    p7_hmm_Sample(r, M, abc, &hmm);
    gm = p7_profile_Create(M, abc); om = p7_oprofile_Create(M, abc);
    p7_ProfileConfig(hmm, bg, gm, 400, p7_LOCAL); p7_oprofile_Convert(gm, om);
    for (n = 0; n < nseq; n++) {
      int L;
      if (n % 2) { L = 1 + esl_rnd_Roll(r, 1500); esl_sq_GrowTo(sq, L); esl_rsq_xfIID(r, bg->f, abc->K, L, sq->dsq); sq->n = L; }
      else       { esl_sq_Reuse(sq); p7_ProfileEmit(r, hmm, gm, bg, sq, NULL); L = sq->n; }
      p7_oprofile_ReconfigLength(om, L);
      t = now(); for (k = 0; k < reps; k++) st1 = p7_SSVFilter(sq->dsq, L, om, &sc1); tsse += now() - t;
      t = now(); for (k = 0; k < reps; k++) st2 = p7_SSVFilter(sq->dsq, L, om, &sc2); tavx += now() - t;
      printf("M %d n %d L %d sse %d %.6f avx %d %.6f\n", M, n, L, st1, sc1, st2, sc2);
    }
    esl_sq_Destroy(sq); p7_oprofile_Destroy(om); p7_profile_Destroy(gm); p7_hmm_Destroy(hmm);
  }
  fprintf(stderr, "time sse %.3f s avx %.3f s\n", tsse, tavx);
  return 0;
}
