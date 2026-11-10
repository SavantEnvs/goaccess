/*
 * Linked into the AFL goaccess CLI target only: point stdin at /dev/null before main().
 *
 * The target reads its log from `-f @@`; stdin carries no fuzz input. But goaccess treats a
 * non-tty stdin as an extra piped log ("-"), and when it can also open a terminal it reads that
 * pipe with a blocking read (set_pipe_stdin(), src/goaccess.c). Mayhem's regression phase runs the
 * target with an inherited stdin pipe that stays open, so every input hung past the exec timeout.
 * With /dev/null the extra "-" log hits EOF at once; the parsed input is unchanged.
 */
#include <fcntl.h>
#include <unistd.h>

__attribute__((constructor)) static void mayhem_stdin_null(void) {
  int fd = open("/dev/null", O_RDONLY);
  if (fd > 0) {
    dup2(fd, STDIN_FILENO);
    close(fd);
  }
}
