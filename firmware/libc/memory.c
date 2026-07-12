/* Minimal freestanding memory routines used by LLVM aggregate lowering. */

typedef __SIZE_TYPE__ size_t;

void *memcpy(void *restrict destination, const void *restrict source,
             size_t count) {
  unsigned char *out = (unsigned char *)destination;
  const unsigned char *in = (const unsigned char *)source;
  while (count--)
    *out++ = *in++;
  return destination;
}

void *memmove(void *destination, const void *source, size_t count) {
  unsigned char *out = (unsigned char *)destination;
  const unsigned char *in = (const unsigned char *)source;
  if (out < in) {
    while (count--)
      *out++ = *in++;
  } else if (out != in) {
    out += count;
    in += count;
    while (count--)
      *--out = *--in;
  }
  return destination;
}

void *memset(void *destination, int value, size_t count) {
  unsigned char *out = (unsigned char *)destination;
  while (count--)
    *out++ = (unsigned char)value;
  return destination;
}
