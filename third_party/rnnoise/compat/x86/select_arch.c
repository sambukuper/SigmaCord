/* Não é do RNNoise: o melhor caminho que este processador e o sistema aguentam
   (dnn_x86.h). SIGMACORD_RNNOISE_ARCH força um mais baixo, para testar. */
#include <cpuid.h>
#include <stdlib.h>

static int detect(void) {
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
    /* OSXSAVE e AVX. */
    const unsigned avx = (1u << 27) | (1u << 28);
    if ((c & avx) != avx) return 0;
    const unsigned has_fma = c & (1u << 12);
    /* O sistema salva os registradores YMM. */
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    (void)hi;
    if ((lo & 6) != 6) return 0;
    if (!has_fma || !__get_cpuid_count(7, 0, &a, &b, &c, &d)) return 1;
    return (b & (1u << 5)) ? 2 : 1;
}

int rnn_select_arch(void) {
    int arch = detect();
    const char *force = getenv("SIGMACORD_RNNOISE_ARCH");
    if (force && force[0] >= '0' && force[0] - '0' < arch) arch = force[0] - '0';
    return arch;
}
