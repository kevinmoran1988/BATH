/* latency of one chained op, in units of a scalar add (1 cycle on every x86 core) */
#include <immintrin.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+1e-9*t.tv_nsec;}
#define N 400000000L
int main(void){
  double t,best[5]={1e9,1e9,1e9,1e9,1e9}; int r; long i;
  volatile uint64_t seed=3; uint64_t a; __m256i v,w; __m128i x,y;
  for(r=0;r<5;r++){
    a=seed; t=now(); for(i=0;i<N;i++){ __asm__ volatile("add %%rcx,%0\n add %%rcx,%0\n add %%rcx,%0\n add %%rcx,%0" : "+r"(a) : "c"(seed)); } t=(now()-t)/(4.0*N); if(t<best[0])best[0]=t;
    v=_mm256_set1_epi8((char)seed); w=_mm256_set1_epi8(1);
    t=now(); for(i=0;i<N;i++){ __asm__ volatile("vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0" : "+x"(v) : "x"(w)); } t=(now()-t)/(4.0*N); if(t<best[1])best[1]=t;
    t=now(); for(i=0;i<N;i++){ __asm__ volatile("vpsubsb %1,%0,%0\n vpsubsb %1,%0,%0\n vpsubsb %1,%0,%0\n vpsubsb %1,%0,%0" : "+x"(v) : "x"(w)); } t=(now()-t)/(4.0*N); if(t<best[2])best[2]=t;
    x=_mm_set1_epi8((char)seed); y=_mm_set1_epi8(1);
    t=now(); for(i=0;i<N;i++){ __asm__ volatile("vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0\n vpmaxub %1,%0,%0" : "+x"(x) : "x"(y)); } t=(now()-t)/(4.0*N); if(t<best[3])best[3]=t;
    t=now(); for(i=0;i<N;i++){ __asm__ volatile("vpaddb %1,%0,%0\n vpaddb %1,%0,%0\n vpaddb %1,%0,%0\n vpaddb %1,%0,%0" : "+x"(v) : "x"(w)); } t=(now()-t)/(4.0*N); if(t<best[4])best[4]=t;
  }
  printf("scalar add        %.3f ns per op (taken as 1 cycle)\n",best[0]*1e9);
  printf("vpmaxub ymm chain %.3f ns = %.2f cycles\n",best[1]*1e9,best[1]/best[0]);
  printf("vpsubsb ymm chain %.3f ns = %.2f cycles\n",best[2]*1e9,best[2]/best[0]);
  printf("vpmaxub xmm chain %.3f ns = %.2f cycles\n",best[3]*1e9,best[3]/best[0]);
  printf("vpaddb  ymm chain %.3f ns = %.2f cycles\n",best[4]*1e9,best[4]/best[0]);
  return 0; }
