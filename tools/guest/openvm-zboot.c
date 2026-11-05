/* openvm-zboot: unpacks a raw arm64 kernel Image from an EFI zboot container.
 *
 * Alpine ships vmlinuz-virt as "MZ" + "zimg" around a gzip payload, and
 * VZLinuxBootLoader needs the raw Image. The container holds other bytes that look
 * like a gzip header, so each one is tried until a payload inflates to something
 * with the arm64 magic ("ARMd" at offset 0x38).
 *
 * usage: openvm-zboot <in> <out>
 * Exit status: 0 unpacked, 1 failed, 3 the input is not a zboot container.
 * Built by tools/build/fetch-linux.sh on the host and by the installer in the guest. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define MAX_IMAGE (512u << 20)

static unsigned char *read_all(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (f == NULL)
        return NULL;
    size_t cap = 1u << 24, n = 0, got;
    unsigned char *data = malloc(cap);
    while (data != NULL && (got = fread(data + n, 1, cap - n, f)) > 0) {
        n += got;
        if (n == cap) {
            unsigned char *bigger = realloc(data, cap * 2);
            if (bigger == NULL) {
                free(data);
                data = NULL;
                break;
            }
            data = bigger;
            cap *= 2;
        }
    }
    fclose(f);
    *len = n;
    return data;
}

/* Inflates one gzip stream. Returns the image, or NULL if this is not a whole one. */
static unsigned char *inflate_at(const unsigned char *in, size_t in_len, size_t *out_len) {
    z_stream z;
    memset(&z, 0, sizeof z);
    if (inflateInit2(&z, 31) != Z_OK) /* 31: gzip framing */
        return NULL;
    size_t cap = 1u << 26;
    unsigned char *out = malloc(cap);
    z.next_in = (unsigned char *)in;
    z.avail_in = in_len > 0xFFFFFFFFu ? 0xFFFFFFFFu : (unsigned)in_len;
    int status = Z_OK;
    while (out != NULL && status == Z_OK) {
        z.next_out = out + z.total_out;
        z.avail_out = (unsigned)(cap - z.total_out);
        status = inflate(&z, Z_NO_FLUSH);
        if (status == Z_OK && z.avail_out == 0) {
            if (cap >= MAX_IMAGE) {
                status = Z_MEM_ERROR;
                break;
            }
            unsigned char *bigger = realloc(out, cap * 2);
            if (bigger == NULL) {
                status = Z_MEM_ERROR;
                break;
            }
            out = bigger;
            cap *= 2;
        } else if (status == Z_OK && z.avail_in == 0) {
            status = Z_DATA_ERROR; /* the stream stopped short */
        }
    }
    *out_len = z.total_out;
    inflateEnd(&z);
    if (status != Z_STREAM_END) {
        free(out);
        return NULL;
    }
    return out;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: openvm-zboot <in> <out>\n");
        return 1;
    }
    size_t len = 0;
    unsigned char *data = read_all(argv[1], &len);
    if (data == NULL) {
        perror(argv[1]);
        return 1;
    }
    if (len < 8 || memcmp(data, "MZ\0\0zimg", 8) != 0) {
        fprintf(stderr, "openvm-zboot: %s is not a zboot container\n", argv[1]);
        return 3;
    }
    for (size_t i = 0; i + 3 <= len; i++) {
        if (data[i] != 0x1f || data[i + 1] != 0x8b || data[i + 2] != 0x08)
            continue;
        size_t image_len = 0;
        unsigned char *image = inflate_at(data + i, len - i, &image_len);
        if (image == NULL)
            continue; /* a false signature */
        if (image_len >= 0x3c && memcmp(image + 0x38, "ARMd", 4) == 0) {
            FILE *f = fopen(argv[2], "wb");
            if (f == NULL || fwrite(image, 1, image_len, f) != image_len || fclose(f) != 0) {
                perror(argv[2]);
                return 1;
            }
            printf("extracted raw arm64 Image (%zu bytes) from zboot container\n", image_len);
            return 0;
        }
        free(image);
    }
    fprintf(stderr, "openvm-zboot: no gzip payload decoding to a raw arm64 Image\n");
    return 1;
}
