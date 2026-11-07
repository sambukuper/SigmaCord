/* Não é do RNNoise: vec_neon.h e o caminho sem vetor de vec.h incluem este
   arquivo, que o pacote 0.2 não traz, e só precisam desta macro. x86-64 não
   passa por aqui. Evita alterar os arquivos do pacote. */
#ifndef SIGMACORD_RNNOISE_OS_SUPPORT_H
#define SIGMACORD_RNNOISE_OS_SUPPORT_H
#include <string.h>
#define OPUS_CLEAR(dst, n) (memset((dst), 0, (n) * sizeof(*(dst))))
#endif
