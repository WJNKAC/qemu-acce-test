/* 与 init/init.c 里 bench_alu / bench_mem 逐字相同的负载，原生跑一遍做分母。 */
#include <stdio.h>
#include <time.h>
#include <stdbool.h>
static double mono(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static double bench_alu(long iters){
    unsigned long long a=1,b=3,c=5,d=7; double t0=mono();
    for(long i=0;i<iters;i++){
        a=a*6364136223846793005ull+1442695040888963407ull;
        b^=a>>17;b+=i;c+=a^b;c=(c<<7)|(c>>57);d-=c*3+b;a^=d>>11;
    }
    double t1=mono(); volatile unsigned long long s=a^b^c^d;(void)s;
    return (t1-t0)*1e9/(double)iters;
}
static double bench_mem(long iters){
    static unsigned int arr[8192];
    for(int i=0;i<8192;i++)arr[i]=(unsigned)i*2654435761u;
    unsigned long long acc=0; double t0=mono();
    for(long i=0;i<iters;i++){
        unsigned idx=(unsigned)(acc+(unsigned long long)i)&8191u;
        unsigned v=arr[idx]; arr[idx]=v+1u; acc+=v*3u+1u; acc^=acc>>7;
    }
    double t1=mono(); volatile unsigned long long s=acc;(void)s;
    return (t1-t0)*1e9/(double)iters;
}
int main(void){
    long n=30000000; bench_alu(n/10); bench_mem(n/10);
    printf("native: alu %.2f ns/iter   mem %.2f ns/iter\n", bench_alu(n), bench_mem(n));
    return 0;
}
