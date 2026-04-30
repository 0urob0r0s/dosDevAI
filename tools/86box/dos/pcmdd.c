/*
 * pcmdd.c — Persistent DOS shell REPL over COM2.
 *
 * Reads length-prefixed command strings from COM2, runs each via
 * COMMAND.COM (capturing stdout to a temp file), and writes the response
 * (length + errorlevel + stdout) back over COM2. Loops forever — used
 * by the host-side `86box-pcmd` to send commands into a long-lived 86Box
 * session without paying the ~30 s cold-boot cost per call.
 *
 * Wire protocol (all lengths little-endian):
 *
 *   Request   host -> DOS:  uint16 cmd_len, byte cmd[cmd_len]
 *   Response  DOS  -> host: uint16 out_len, uint8 errorlevel, byte out[out_len]
 *
 * Build:    wcl -bt=dos -ms -0 -os -fe=PCMDD.EXE pcmdd.c seruart.c
 *
 * Boot:     installed at C:\PCMDD.EXE; AUTOEXEC.BAT runs it as the very
 *           last command so the DOS prompt is never reached. Pcmdd never
 *           returns — kill the 86Box process to terminate.
 *
 * COM2 setup: 9600 baud 8N1, no flow control. Host-side bridge handles
 *             raw termios + the ~4 ms/byte throttle that 86Box's emulated
 *             UART needs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>

#include "seruart.h"

#define COM_PORT     SERUART_COM2
#define BAUD_DIV     SERUART_DIV_9600

#define OUT_FILE     "C:\\PCMD.OUT"
#define MAX_CMD_LEN  512u
#define MAX_OUT_LEN  16384u

static unsigned char rx_buf[MAX_CMD_LEN + 4u];
static unsigned char tx_buf[MAX_OUT_LEN + 8u];
static char shell_cmd[MAX_CMD_LEN + 64u];

static unsigned int read_exact(unsigned int n)
{
    unsigned int got = 0u;
    /* Per-call deadline: we never want pcmdd to wedge if a single read
     * stalls. 18 ticks/s * 60 = ~3 s per byte budget — plenty. */
    while (got < n) {
        unsigned int chunk = seruart_recv_block_timeout(
            COM_PORT, rx_buf + got, n - got, 60u * 18u);
        if (chunk == 0u) {
            /* No bytes in the window — bail; client will retry. */
            return 0u;
        }
        got += chunk;
    }
    return got;
}

int main(void)
{
    seruart_init(COM_PORT, BAUD_DIV);
    /* Drain any boot junk in the UART RX buffer. */
    seruart_drain(COM_PORT);

    printf("pcmdd ready on COM2 @ 9600 baud\n");
    fflush(stdout);

    for (;;) {
        unsigned int cmd_len, n;
        unsigned long out_len;
        int outfd, rc;

        /* 1. Read the 2-byte length prefix. */
        if (read_exact(2u) != 2u) continue;
        cmd_len = (unsigned int)rx_buf[0] | ((unsigned int)rx_buf[1] << 8);
        if (cmd_len == 0u || cmd_len > MAX_CMD_LEN) {
            seruart_drain(COM_PORT);
            continue;
        }

        /* 2. Read the command itself. */
        if (read_exact(cmd_len) != cmd_len) continue;
        rx_buf[cmd_len] = '\0';

        /* 3. Spawn `COMMAND.COM /C <cmd> > C:\PCMD.OUT` via libc system().
         *    The shell handles the redirect for us; we just need the file
         *    afterwards. */
        sprintf(shell_cmd, "%s > %s", (char *)rx_buf, OUT_FILE);
        rc = system(shell_cmd);

        /* 4. Read the captured stdout. */
        out_len = 0uL;
        outfd = open(OUT_FILE, O_RDONLY | O_BINARY);
        if (outfd >= 0) {
            int r = read(outfd, tx_buf + 3u, (unsigned int)MAX_OUT_LEN);
            close(outfd);
            if (r > 0) out_len = (unsigned long)r;
        }

        /* 5. Send response: uint16 length, uint8 errorlevel, output bytes. */
        tx_buf[0] = (unsigned char)(out_len & 0xFFu);
        tx_buf[1] = (unsigned char)((out_len >> 8) & 0xFFu);
        tx_buf[2] = (unsigned char)(rc & 0xFFu);
        n = 3u + (unsigned int)out_len;
        seruart_send_block(COM_PORT, tx_buf, n);
    }
    /* unreachable */
}
