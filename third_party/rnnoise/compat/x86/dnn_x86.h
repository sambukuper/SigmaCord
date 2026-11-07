/* Não é do RNNoise: o pacote tira a detecção de CPU daqui, e src/nnet.h inclui este
   arquivo quando RNN_ENABLE_X86_RTCD está ligado. A release roda em qualquer x86-64
   e compila para o mínimo comum; a rede neural, que é onde o tempo vai, escolhe o
   caminho na hora de rodar: 2 AVX2 + FMA, 1 AVX, 0 o mínimo (select_arch.c).
   Evita alterar os arquivos do pacote. */
#ifndef SIGMACORD_RNNOISE_DNN_X86_H
#define SIGMACORD_RNNOISE_DNN_X86_H

void compute_linear_avx(const LinearLayer *linear, float *out, const float *in);
void compute_activation_avx(float *output, const float *input, int N, int activation);
void compute_conv2d_avx(const Conv2dLayer *conv, float *out, float *mem, const float *in, int height, int hstride, int activation);
void compute_linear_avx2(const LinearLayer *linear, float *out, const float *in);
void compute_activation_avx2(float *output, const float *input, int N, int activation);
void compute_conv2d_avx2(const Conv2dLayer *conv, float *out, float *mem, const float *in, int height, int hstride, int activation);

#define SIGMACORD_RTCD(arch, name) ((arch) == 2 ? name##_avx2 : (arch) == 1 ? name##_avx : name##_c)

#define OVERRIDE_COMPUTE_LINEAR
#define compute_linear(linear, out, in, arch) SIGMACORD_RTCD(arch, compute_linear)(linear, out, in)
#define OVERRIDE_COMPUTE_ACTIVATION
#define compute_activation(output, input, N, activation, arch) SIGMACORD_RTCD(arch, compute_activation)(output, input, N, activation)
#define OVERRIDE_COMPUTE_CONV2D
#define compute_conv2d(conv, out, mem, in, height, hstride, activation, arch) SIGMACORD_RTCD(arch, compute_conv2d)(conv, out, mem, in, height, hstride, activation)

#endif
