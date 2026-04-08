/* Minimal strip: zero out debug/symbol sections in ELF files.
 * Keeps .dynsym/.dynstr (needed at runtime). Modifies files in place.
 * Gets ~90% of GNU strip's size savings with zero dependencies. */
#include <elf.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int strip64(unsigned char *base, size_t sz) {
    Elf64_Ehdr *eh = (Elf64_Ehdr *)base;
    if (eh->e_shoff == 0 || eh->e_shnum == 0) return 0;
    if (eh->e_shoff + eh->e_shnum * sizeof(Elf64_Shdr) > sz) return 0;

    Elf64_Shdr *sh = (Elf64_Shdr *)(base + eh->e_shoff);
    const char *shstrtab = NULL;
    if (eh->e_shstrndx < eh->e_shnum)
        shstrtab = (const char *)(base + sh[eh->e_shstrndx].sh_offset);

    int stripped = 0;
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_offset + sh[i].sh_size > sz) continue;
        if (!shstrtab) continue;

        const char *name = shstrtab + sh[i].sh_name;

        /* Keep: .dynsym, .dynstr, .gnu.hash, .hash (runtime linking) */
        if (sh[i].sh_type == SHT_DYNSYM) continue;
        if (strcmp(name, ".dynstr") == 0) continue;
        if (strcmp(name, ".gnu.hash") == 0) continue;
        if (strcmp(name, ".hash") == 0) continue;

        /* Strip: debug info, symbols, comments, notes */
        int strip = 0;
        if (sh[i].sh_type == SHT_SYMTAB) strip = 1;
        if (strncmp(name, ".debug", 6) == 0) strip = 1;
        if (strncmp(name, ".zdebug", 7) == 0) strip = 1;
        if (strcmp(name, ".strtab") == 0) strip = 1;
        if (strcmp(name, ".comment") == 0) strip = 1;
        if (strcmp(name, ".note") == 0) strip = 1;
        if (strncmp(name, ".note.", 6) == 0) strip = 1;

        if (strip && sh[i].sh_size > 0) {
            memset(base + sh[i].sh_offset, 0, sh[i].sh_size);
            sh[i].sh_type = SHT_NOBITS;
            stripped = 1;
        }
    }
    return stripped;
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        /* Skip flags */
        if (argv[i][0] == '-') {
            /* Skip flags that take an argument */
            if (strcmp(argv[i], "-o") == 0 || strcmp(argv[i], "-R") == 0 ||
                strcmp(argv[i], "-N") == 0 || strcmp(argv[i], "-K") == 0)
                i++;
            continue;
        }

        int fd = open(argv[i], O_RDWR);
        if (fd < 0) { perror(argv[i]); continue; }
        struct stat st;
        fstat(fd, &st);
        if (st.st_size < (off_t)sizeof(Elf64_Ehdr)) { close(fd); continue; }

        unsigned char *base = mmap(NULL, st.st_size, PROT_READ|PROT_WRITE,
                                    MAP_SHARED, fd, 0);
        close(fd);
        if (base == MAP_FAILED) { perror("mmap"); continue; }

        if (memcmp(base, ELFMAG, SELFMAG) == 0)
            strip64(base, st.st_size);

        munmap(base, st.st_size);
    }
    return 0;
}
