#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sched.h>
#include <pthread.h>
static uint64_t N; static volatile uint64_t g_chk; static uint64_t work(uint64_t n){uint64_t x=88172645463325252ull;for(uint64_t i=0;i<n;i++){x^=x<<13;x^=x>>7;x^=x<<17;}return x;}
static void *thr(void *a){*(uint64_t*)a=work(N);g_chk^=*(uint64_t*)a;return NULL;}
static uint64_t now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;}
int main(void){setvbuf(stdout,NULL,_IONBF,0);cpu_set_t s;CPU_ZERO(&s);sched_getaffinity(0,sizeof s,&s);int c=CPU_COUNT(&s);int T=c>4?4:(c<1?1:c);
 N=2000000;uint64_t t0=now();uint64_t a=work(N);uint64_t t1=now();double per=(double)(t1-t0)/N;if(per>0)N=(uint64_t)(0.5e9/per);if(N<1000000)N=1000000;if(N>400000000ull)N=400000000ull;
 t0=now();a=work(N);uint64_t t1a=now()-t0;g_chk^=a;t0=now();a^=work(N);g_chk^=a;uint64_t t1b=now()-t0;uint64_t t1n=t1a<t1b?t1a:t1b;
 uint64_t t2=0,t4=0;for(int T=2;T<=4;T+=2){uint64_t pr[4]={0,0,0,0};pthread_t th[4];uint64_t ta,tb;if(T>c)break;
  t0=now();for(int i=0;i<T;i++)pthread_create(&th[i],0,thr,&pr[i]);for(int i=0;i<T;i++)pthread_join(th[i],0);ta=now()-t0;
  t0=now();for(int i=0;i<T;i++)pthread_create(&th[i],0,thr,&pr[i]);for(int i=0;i<T;i++)pthread_join(th[i],0);tb=now()-t0;
  if(T==2)t2=ta<tb?ta:tb;else t4=ta<tb?ta:tb;}
 printf("HOSTBENCH cpus=%d n=%llu t1_us=%llu t2_us=%llu t4_us=%llu p2_x1000=%llu p4_x1000=%llu chk=%llx\n",c,(unsigned long long)N,(unsigned long long)(t1n/1000),(unsigned long long)(t2/1000),(unsigned long long)(t4/1000),(unsigned long long)(t2?(2ull*t1n*1000ull/t2):0),(unsigned long long)(t4?(4ull*t1n*1000ull/t4):0),(unsigned long long)g_chk);return 0;}
