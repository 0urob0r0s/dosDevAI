/*
 * hello.c — minimal DOS reference program for the 86Box + Open Watcom
 * sandbox. Prints a greeting and echoes its argv so a smoke test can
 * verify the full build → install → run loop works end-to-end.
 *
 * Build:   wcl -bt=dos -ms -0 -os -fe=build/HELLO.EXE src/hello.c
 * Install: 86box-install-dos --to 'C:\HELLO' build/HELLO.EXE
 * Run:     86box-cmd "C:\\HELLO\\HELLO.EXE one two three"
 *
 * Output (with no args):
 *     Hello from DOS!
 *     argc=1
 *
 * Output (with args):
 *     Hello from DOS!
 *     argc=4
 *     argv[1]=one
 *     argv[2]=two
 *     argv[3]=three
 */
#include <stdio.h>

int main(int argc, char *argv[])
{
    int i;

    printf("Hello from DOS!\n");
    printf("argc=%d\n", argc);
    for (i = 1; i < argc; i++) {
        printf("argv[%d]=%s\n", i, argv[i]);
    }
    return 0;
}
